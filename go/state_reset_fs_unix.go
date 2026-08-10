//go:build android || darwin || ios || linux

package tailscale

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// stateResetFilesystem keeps the configured root directory open for the whole
// marker -> custody delete -> subtree delete transaction. The caller must hold
// the root's state lease until Close returns. Keeping this handle avoids
// reopening a replaced path between the two filesystem phases.
type stateResetFilesystem struct {
	baseRoot string
	root     *os.File
	rootInfo os.FileInfo
	hooks    stateResetFSHooks

	markerDurable bool
	closed        bool
}

type stateResetFSHooks struct {
	fsync    func(int) error
	unlinkat func(int, string, int) error
	renameat func(int, string, int, string) error
}

type stateResetFSOption func(*stateResetFSHooks)

func withStateResetFSHooksForTest(hooks stateResetFSHooks) stateResetFSOption {
	return func(configured *stateResetFSHooks) {
		if hooks.fsync != nil {
			configured.fsync = hooks.fsync
		}
		if hooks.unlinkat != nil {
			configured.unlinkat = hooks.unlinkat
		}
		if hooks.renameat != nil {
			configured.renameat = hooks.renameat
		}
	}
}

func defaultStateResetFSHooks() stateResetFSHooks {
	return stateResetFSHooks{
		fsync:    unix.Fsync,
		unlinkat: unix.Unlinkat,
		renameat: unix.Renameat,
	}
}

// openStateResetFilesystem opens and pins the exact configured root inode.
// expectedRoot must be the configured root identity that was used while
// acquiring the caller-owned state lease.
func openStateResetFilesystem(
	baseRoot string,
	expectedRoot os.FileInfo,
	options ...stateResetFSOption,
) (*stateResetFilesystem, error) {
	if strings.TrimSpace(baseRoot) == "" {
		return nil, fmt.Errorf("open reset filesystem: state root is empty")
	}
	if !filepath.IsAbs(baseRoot) {
		return nil, fmt.Errorf("open reset filesystem: state root is not absolute")
	}
	baseRoot = filepath.Clean(baseRoot)
	if filepath.Dir(baseRoot) == baseRoot {
		return nil, fmt.Errorf("open reset filesystem: filesystem root is not a valid state root")
	}
	if expectedRoot == nil {
		return nil, fmt.Errorf("open reset filesystem: expected root identity is missing")
	}
	hooks := defaultStateResetFSHooks()
	for _, apply := range options {
		if apply != nil {
			apply(&hooks)
		}
	}

	fd, err := unix.Open(baseRoot, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open reset root: %w", err)
	}
	root := os.NewFile(uintptr(fd), baseRoot)
	if root == nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("open reset root: invalid file descriptor")
	}

	fail := func(err error) (*stateResetFilesystem, error) {
		if closeErr := root.Close(); closeErr != nil {
			return nil, errors.Join(err, fmt.Errorf("close reset root: %w", closeErr))
		}
		return nil, err
	}
	rootInfo, err := root.Stat()
	if err != nil {
		return fail(fmt.Errorf("stat reset root: %w", err))
	}
	if !rootInfo.IsDir() {
		return fail(fmt.Errorf("reset root is not a directory"))
	}
	if !sameStateResetFile(expectedRoot, rootInfo) {
		return fail(fmt.Errorf("reset root does not match the configured root"))
	}
	if err := verifyCurrentUserOwns(rootInfo); err != nil {
		return fail(fmt.Errorf("verify reset root owner: %w", err))
	}
	if got := rootInfo.Mode().Perm(); got != 0o700 {
		return fail(fmt.Errorf("reset root permissions are %04o, want 0700", got))
	}

	reset := &stateResetFilesystem{
		baseRoot: baseRoot,
		root:     root,
		rootInfo: rootInfo,
		hooks:    hooks,
	}
	if err := reset.verifyRootPath(); err != nil {
		return fail(err)
	}
	return reset, nil
}

// ensureDurableMarker creates or verifies the exact reset marker, fsyncs the
// marker, and fsyncs the configured root. It must complete before custody is
// mutated. Invalid file-like entries (including symlinks) are atomically
// replaced without being followed; a directory at the marker path fails
// closed.
func (r *stateResetFilesystem) ensureDurableMarker() error {
	if err := r.usable(); err != nil {
		return err
	}
	if err := r.verifyRootPath(); err != nil {
		return err
	}

	valid, err := r.verifyMarker(false)
	if err != nil {
		return fmt.Errorf("verify reset marker: %w", err)
	}
	if !valid {
		if err := r.replaceMarker(); err != nil {
			return err
		}
	}
	valid, err = r.verifyMarker(true)
	if err != nil {
		return fmt.Errorf("verify reset marker before commit: %w", err)
	}
	if !valid {
		return fmt.Errorf("%w: marker did not match after creation", errStateResetMarkerInvalid)
	}
	if err := r.hooks.fsync(int(r.root.Fd())); err != nil {
		return fmt.Errorf("sync reset marker directory: %w", err)
	}
	if err := r.verifyRootPath(); err != nil {
		return err
	}
	valid, err = r.verifyMarker(false)
	if err != nil {
		return fmt.Errorf("revalidate durable reset marker: %w", err)
	}
	if !valid {
		return fmt.Errorf("%w: marker changed during commit", errStateResetMarkerInvalid)
	}
	r.markerDurable = true
	return nil
}

// completeAfterCustodyDeletion removes only the root-confined tailscale entry,
// syncs that deletion, then removes and syncs the marker. It is intentionally
// named for its ordering precondition: callers invoke it only after Keybay has
// confirmed deletion of the exact DEK entry. Every ordinary failure before the
// final marker commit leaves (or best-effort restores) the marker for retry.
func (r *stateResetFilesystem) completeAfterCustodyDeletion() error {
	if err := r.usable(); err != nil {
		return err
	}
	if !r.markerDurable {
		return fmt.Errorf("refuse local-state deletion without a durable reset marker")
	}
	if err := r.verifyRootPath(); err != nil {
		return fmt.Errorf("%w: %w", ErrLocalResetIncomplete, err)
	}
	valid, err := r.verifyMarker(false)
	if err != nil {
		return fmt.Errorf("%w: verify reset marker: %w", ErrLocalResetIncomplete, err)
	}
	if !valid {
		return fmt.Errorf("%w: %w", ErrLocalResetIncomplete, errStateResetMarkerInvalid)
	}

	if err := r.removeOwnedStateSubtree(); err != nil {
		return fmt.Errorf("%w: remove package-owned state: %w", ErrLocalResetIncomplete, err)
	}
	if err := r.hooks.fsync(int(r.root.Fd())); err != nil {
		return fmt.Errorf("%w: sync package-state removal: %w", ErrLocalResetIncomplete, err)
	}
	if err := r.verifyRootPath(); err != nil {
		return fmt.Errorf("%w: %w", ErrLocalResetIncomplete, err)
	}
	valid, err = r.verifyMarker(false)
	if err != nil {
		return fmt.Errorf("%w: revalidate reset marker: %w", ErrLocalResetIncomplete, err)
	}
	if !valid {
		return fmt.Errorf("%w: %w", ErrLocalResetIncomplete, errStateResetMarkerInvalid)
	}

	if err := r.hooks.unlinkat(int(r.root.Fd()), stateResetMarkerFilename, 0); err != nil {
		return fmt.Errorf("%w: remove reset marker: %w", ErrLocalResetIncomplete, err)
	}
	if err := r.hooks.fsync(int(r.root.Fd())); err != nil {
		// The subtree is already absent, but without the directory sync we cannot
		// claim that marker removal is durable. Re-establish durable intent when
		// possible so the next explicit reset can retry safely.
		return r.restoreMarkerAfterCompletionFailure("sync reset completion", err)
	}
	if err := r.verifyRootPath(); err != nil {
		return r.restoreMarkerAfterCompletionFailure("revalidate configured root after reset", err)
	}
	if _, err := r.lstatAt(stateResetMarkerFilename); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return fmt.Errorf("%w: reset marker was recreated", ErrLocalResetIncomplete)
		}
		return r.restoreMarkerAfterCompletionFailure("verify reset marker absence", err)
	}
	r.markerDurable = false
	return nil
}

func (r *stateResetFilesystem) restoreMarkerAfterCompletionFailure(context string, primary error) error {
	restoreErr := r.replaceAndCommitMarker()
	if restoreErr != nil {
		return fmt.Errorf("%w: %s: %w; restore marker: %v", ErrLocalResetIncomplete, context, primary, restoreErr)
	}
	r.markerDurable = true
	return fmt.Errorf("%w: %s: %w", ErrLocalResetIncomplete, context, primary)
}

func (r *stateResetFilesystem) Close() error {
	if r == nil || r.closed {
		return nil
	}
	r.closed = true
	return r.root.Close()
}

func (r *stateResetFilesystem) usable() error {
	if r == nil || r.root == nil || r.closed {
		return fmt.Errorf("reset filesystem is closed")
	}
	return nil
}

func (r *stateResetFilesystem) verifyRootPath() error {
	current, err := os.Lstat(r.baseRoot)
	if err != nil {
		return fmt.Errorf("revalidate configured reset root: %w", err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.IsDir() {
		return fmt.Errorf("configured reset root is no longer a real directory")
	}
	if !sameStateResetFile(r.rootInfo, current) {
		return fmt.Errorf("configured reset root was replaced")
	}
	return nil
}

func (r *stateResetFilesystem) verifyMarker(syncFile bool) (bool, error) {
	pathInfo, err := r.lstatAt(stateResetMarkerFilename)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if pathInfo.Mode()&os.ModeSymlink != 0 || !pathInfo.Mode().IsRegular() {
		return false, nil
	}

	fd, err := unix.Openat(int(r.root.Fd()), stateResetMarkerFilename, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if errors.Is(err, unix.ELOOP) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	file := os.NewFile(uintptr(fd), filepath.Join(r.baseRoot, stateResetMarkerFilename))
	if file == nil {
		_ = unix.Close(fd)
		return false, fmt.Errorf("invalid marker file descriptor")
	}
	defer file.Close()

	opened, err := file.Stat()
	if err != nil {
		return false, err
	}
	if !opened.Mode().IsRegular() || !sameStateResetFile(pathInfo, opened) {
		return false, nil
	}
	if err := verifyCurrentUserOwns(opened); err != nil {
		return false, nil
	}
	if opened.Mode().Perm() != 0o600 || opened.Size() != int64(len(stateResetMarkerPayload)) {
		return false, nil
	}
	payload, err := io.ReadAll(io.LimitReader(file, int64(len(stateResetMarkerPayload)+1)))
	if err != nil {
		return false, err
	}
	if !bytes.Equal(payload, []byte(stateResetMarkerPayload)) {
		return false, nil
	}
	if syncFile {
		if err := r.hooks.fsync(fd); err != nil {
			return false, err
		}
	}
	current, err := r.lstatAt(stateResetMarkerFilename)
	if err != nil {
		return false, err
	}
	if !sameStateResetFile(opened, current) {
		return false, fmt.Errorf("reset marker path was replaced")
	}
	return true, nil
}

func (r *stateResetFilesystem) replaceMarker() error {
	if err := r.removeStaleMarkerTemp(); err != nil {
		return fmt.Errorf("prepare reset marker temp: %w", err)
	}

	fd, err := unix.Openat(
		int(r.root.Fd()),
		stateResetMarkerTempFilename,
		unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return fmt.Errorf("create reset marker temp: %w", err)
	}
	file := os.NewFile(uintptr(fd), filepath.Join(r.baseRoot, stateResetMarkerTempFilename))
	if file == nil {
		_ = unix.Close(fd)
		return fmt.Errorf("create reset marker temp: invalid file descriptor")
	}
	tempExists := true
	defer func() {
		if tempExists {
			_ = r.hooks.unlinkat(int(r.root.Fd()), stateResetMarkerTempFilename, 0)
		}
	}()

	written, writeErr := file.Write([]byte(stateResetMarkerPayload))
	if writeErr == nil && written != len(stateResetMarkerPayload) {
		writeErr = io.ErrShortWrite
	}
	if writeErr != nil {
		_ = file.Close()
		return fmt.Errorf("write reset marker temp: %w", writeErr)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return fmt.Errorf("secure reset marker temp: %w", err)
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return fmt.Errorf("stat reset marker temp: %w", err)
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return fmt.Errorf("reset marker temp is not a regular file")
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		_ = file.Close()
		return fmt.Errorf("verify reset marker temp owner: %w", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		_ = file.Close()
		return fmt.Errorf("reset marker temp permissions are %04o, want 0600", got)
	}
	if err := r.hooks.fsync(fd); err != nil {
		_ = file.Close()
		return fmt.Errorf("sync reset marker temp: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close reset marker temp: %w", err)
	}

	currentTemp, err := r.lstatAt(stateResetMarkerTempFilename)
	if err != nil {
		return fmt.Errorf("revalidate reset marker temp: %w", err)
	}
	if !sameStateResetFile(info, currentTemp) {
		return fmt.Errorf("reset marker temp path was replaced")
	}
	if err := r.hooks.renameat(
		int(r.root.Fd()),
		stateResetMarkerTempFilename,
		int(r.root.Fd()),
		stateResetMarkerFilename,
	); err != nil {
		return fmt.Errorf("commit reset marker: %w", err)
	}
	tempExists = false
	return nil
}

func (r *stateResetFilesystem) replaceAndCommitMarker() error {
	if err := r.replaceMarker(); err != nil {
		return err
	}
	valid, err := r.verifyMarker(true)
	if err != nil {
		return err
	}
	if !valid {
		return errStateResetMarkerInvalid
	}
	if err := r.hooks.fsync(int(r.root.Fd())); err != nil {
		return err
	}
	return nil
}

func (r *stateResetFilesystem) removeStaleMarkerTemp() error {
	info, err := r.lstatAt(stateResetMarkerTempFilename)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("reset marker temp is a directory")
	}
	if err := r.hooks.unlinkat(int(r.root.Fd()), stateResetMarkerTempFilename, 0); err != nil {
		return err
	}
	return nil
}

func (r *stateResetFilesystem) removeOwnedStateSubtree() error {
	info, err := r.lstatAt(ownedStateSubdirectory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return r.hooks.unlinkat(int(r.root.Fd()), ownedStateSubdirectory, 0)
	}

	dir, opened, err := r.openDirectoryAt(int(r.root.Fd()), ownedStateSubdirectory, info)
	if err != nil {
		return err
	}
	defer dir.Close()
	rootDevice, err := stateResetDevice(r.rootInfo)
	if err != nil {
		return err
	}
	childDevice, err := stateResetDevice(opened)
	if err != nil {
		return err
	}
	if childDevice != rootDevice {
		return fmt.Errorf("package-owned state crosses a filesystem boundary")
	}
	if err := r.removeDirectoryContents(dir, rootDevice, 0); err != nil {
		return err
	}
	current, err := r.lstatAt(ownedStateSubdirectory)
	if err != nil {
		return fmt.Errorf("revalidate package-owned state directory: %w", err)
	}
	if !sameStateResetFile(opened, current) {
		return fmt.Errorf("package-owned state directory was replaced")
	}
	if err := r.hooks.unlinkat(int(r.root.Fd()), ownedStateSubdirectory, unix.AT_REMOVEDIR); err != nil {
		return err
	}
	return nil
}

func (r *stateResetFilesystem) removeDirectoryContents(dir *os.File, rootDevice uint64, depth int) error {
	if depth >= stateResetMaximumDepth {
		return fmt.Errorf("package-owned state exceeds maximum reset depth %d", stateResetMaximumDepth)
	}
	for {
		names, err := dir.Readdirnames(128)
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		for _, name := range names {
			if name == "." || name == ".." {
				return fmt.Errorf("invalid directory entry %q", name)
			}
			info, statErr := lstatAtFD(int(dir.Fd()), name)
			if errors.Is(statErr, os.ErrNotExist) {
				continue
			}
			if statErr != nil {
				return statErr
			}
			if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				if unlinkErr := r.hooks.unlinkat(int(dir.Fd()), name, 0); unlinkErr != nil && !errors.Is(unlinkErr, os.ErrNotExist) {
					return unlinkErr
				}
				continue
			}

			child, opened, openErr := r.openDirectoryAt(int(dir.Fd()), name, info)
			if openErr != nil {
				return openErr
			}
			childDevice, deviceErr := stateResetDevice(opened)
			if deviceErr != nil {
				_ = child.Close()
				return deviceErr
			}
			if childDevice != rootDevice {
				_ = child.Close()
				return fmt.Errorf("state child %q crosses a filesystem boundary", name)
			}
			if removeErr := r.removeDirectoryContents(child, rootDevice, depth+1); removeErr != nil {
				_ = child.Close()
				return removeErr
			}
			if closeErr := child.Close(); closeErr != nil {
				return closeErr
			}
			current, statErr := lstatAtFD(int(dir.Fd()), name)
			if statErr != nil {
				return statErr
			}
			if !sameStateResetFile(opened, current) {
				return fmt.Errorf("state child %q was replaced", name)
			}
			if unlinkErr := r.hooks.unlinkat(int(dir.Fd()), name, unix.AT_REMOVEDIR); unlinkErr != nil {
				return unlinkErr
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
	}
	if err := r.hooks.fsync(int(dir.Fd())); err != nil {
		return err
	}
	return nil
}

func (r *stateResetFilesystem) openDirectoryAt(parentFD int, name string, expected os.FileInfo) (*os.File, os.FileInfo, error) {
	fd, err := unix.Openat(parentFD, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, err
	}
	dir := os.NewFile(uintptr(fd), name)
	if dir == nil {
		_ = unix.Close(fd)
		return nil, nil, fmt.Errorf("open state directory %q: invalid file descriptor", name)
	}
	opened, err := dir.Stat()
	if err != nil {
		_ = dir.Close()
		return nil, nil, err
	}
	if !opened.IsDir() || !sameStateResetFile(expected, opened) {
		_ = dir.Close()
		return nil, nil, fmt.Errorf("state directory %q was replaced", name)
	}
	return dir, opened, nil
}

func (r *stateResetFilesystem) lstatAt(name string) (os.FileInfo, error) {
	return lstatAtFD(int(r.root.Fd()), name)
}

func lstatAtFD(parentFD int, name string) (os.FileInfo, error) {
	var stat unix.Stat_t
	if err := unix.Fstatat(parentFD, name, &stat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, os.NewSyscallError("fstatat", err)
	}
	return stateResetFileInfo{name: name, stat: stat}, nil
}

type stateResetFileInfo struct {
	name string
	stat unix.Stat_t
}

func (i stateResetFileInfo) Name() string       { return i.name }
func (i stateResetFileInfo) Size() int64        { return i.stat.Size }
func (i stateResetFileInfo) Mode() os.FileMode  { return stateResetFileMode(uint32(i.stat.Mode)) }
func (i stateResetFileInfo) ModTime() time.Time { return time.Time{} }
func (i stateResetFileInfo) IsDir() bool        { return i.Mode().IsDir() }
func (i stateResetFileInfo) Sys() any           { return &i.stat }

func stateResetFileMode(mode uint32) os.FileMode {
	permissions := os.FileMode(mode & 0o777)
	switch mode & unix.S_IFMT {
	case unix.S_IFDIR:
		return permissions | os.ModeDir
	case unix.S_IFLNK:
		return permissions | os.ModeSymlink
	case unix.S_IFREG:
		return permissions
	case unix.S_IFIFO:
		return permissions | os.ModeNamedPipe
	case unix.S_IFSOCK:
		return permissions | os.ModeSocket
	case unix.S_IFCHR:
		return permissions | os.ModeDevice | os.ModeCharDevice
	case unix.S_IFBLK:
		return permissions | os.ModeDevice
	default:
		return permissions | os.ModeIrregular
	}
}

func stateResetDevice(info os.FileInfo) (uint64, error) {
	identity, err := stateResetIdentity(info)
	if err != nil {
		return 0, err
	}
	return identity.device, nil
}

type stateResetFileIdentity struct {
	device uint64
	inode  uint64
}

func stateResetIdentity(info os.FileInfo) (stateResetFileIdentity, error) {
	switch stat := info.Sys().(type) {
	case *syscall.Stat_t:
		return stateResetFileIdentity{device: uint64(stat.Dev), inode: uint64(stat.Ino)}, nil
	case *unix.Stat_t:
		return stateResetFileIdentity{device: uint64(stat.Dev), inode: uint64(stat.Ino)}, nil
	default:
		return stateResetFileIdentity{}, fmt.Errorf("device and inode metadata is unavailable")
	}
}

func sameStateResetFile(left, right os.FileInfo) bool {
	leftID, leftErr := stateResetIdentity(left)
	rightID, rightErr := stateResetIdentity(right)
	return leftErr == nil && rightErr == nil && leftID == rightID
}
