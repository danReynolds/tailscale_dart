//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// acquireStateLease acquires the stable lock file below baseRoot without
// waiting. Process-local admission is keyed by the root directory's device and
// inode, while flock protects against other processes.
func acquireStateLease(baseRoot string, option ...stateLeaseOption) (*stateLease, error) {
	if strings.TrimSpace(baseRoot) == "" {
		return nil, fmt.Errorf("persistent state root is empty")
	}
	options := stateLeaseOptions{stateLeaseTestHooks: stateLeaseTestHooks{
		lock: func(fd int) error {
			return unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
		},
		unlock: func(fd int) error {
			return unix.Flock(fd, unix.LOCK_UN)
		},
		close: func(file *os.File) error {
			return file.Close()
		},
	}}
	for _, apply := range option {
		if apply != nil {
			apply(&options)
		}
	}
	baseRoot = filepath.Clean(baseRoot)
	if options.expectedRoot == nil {
		if err := os.MkdirAll(baseRoot, 0o700); err != nil {
			return nil, fmt.Errorf("create persistent state root: %w", err)
		}
	}

	root, err := os.Open(baseRoot)
	if err != nil {
		return nil, fmt.Errorf("open persistent state root: %w", err)
	}
	rootOpen := true
	defer func() {
		if rootOpen {
			_ = root.Close()
		}
	}()

	rootInfo, err := root.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat persistent state root: %w", err)
	}
	if !rootInfo.IsDir() {
		return nil, fmt.Errorf("persistent state root is not a directory")
	}
	if options.expectedRoot != nil && !os.SameFile(options.expectedRoot, rootInfo) {
		return nil, fmt.Errorf("%w: configured state root changed before lease acquisition", ErrConfigurationMismatch)
	}
	if err := verifyCurrentUserOwns(rootInfo); err != nil {
		return nil, fmt.Errorf("verify persistent state root ownership: %w", err)
	}
	if err := root.Chmod(0o700); err != nil {
		return nil, fmt.Errorf("secure persistent state root: %w", err)
	}
	rootInfo, err = root.Stat()
	if err != nil {
		return nil, fmt.Errorf("verify persistent state root: %w", err)
	}
	if got := rootInfo.Mode().Perm(); got != 0o700 {
		return nil, fmt.Errorf("persistent state root permissions are %04o, want 0700", got)
	}
	rootID, err := stateLeaseIdentity(rootInfo)
	if err != nil {
		return nil, fmt.Errorf("identify persistent state root: %w", err)
	}
	admission, err := reserveStateLeaseAdmission(baseRoot, rootID)
	if err != nil {
		return nil, err
	}

	fd, err := unix.Openat(int(root.Fd()), stateLeaseFilename, unix.O_RDWR|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		finishStateLeaseAdmission(rootID, admission, nil)
		return nil, fmt.Errorf("open persistent state lease: %w", err)
	}
	lockFile := os.NewFile(uintptr(fd), filepath.Join(baseRoot, stateLeaseFilename))
	if lockFile == nil {
		_ = unix.Close(fd)
		finishStateLeaseAdmission(rootID, admission, nil)
		return nil, fmt.Errorf("open persistent state lease: invalid file descriptor")
	}

	lockInfo, err := lockFile.Stat()
	if err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("stat persistent state lease: %w", err))
	}
	if !lockInfo.Mode().IsRegular() {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("persistent state lease is not a regular file"))
	}
	if err := verifyCurrentUserOwns(lockInfo); err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("verify persistent state lease ownership: %w", err))
	}
	if err := lockFile.Chmod(0o600); err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("secure persistent state lease: %w", err))
	}
	lockInfo, err = lockFile.Stat()
	if err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("verify persistent state lease: %w", err))
	}
	if got := lockInfo.Mode().Perm(); got != 0o600 {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, fmt.Errorf("persistent state lease permissions are %04o, want 0600", got))
	}
	if err := verifyStateLeasePath(int(root.Fd()), lockInfo); err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, err)
	}

	if err := options.lock(int(lockFile.Fd())); err != nil {
		acquireErr := fmt.Errorf("lock persistent state lease: %w", err)
		if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
			acquireErr = &stateLeaseBusyError{Root: baseRoot}
		}
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, false, acquireErr)
	}
	if err := verifyStateLeasePath(int(root.Fd()), lockInfo); err != nil {
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, true, err)
	}
	if currentRoot, err := os.Stat(baseRoot); err != nil || !os.SameFile(rootInfo, currentRoot) {
		if err == nil {
			err = fmt.Errorf("persistent state root was replaced")
		} else {
			err = fmt.Errorf("revalidate persistent state root: %w", err)
		}
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, true, err)
	}
	if err := root.Close(); err != nil {
		rootOpen = false
		return nil, abandonStateLeaseAcquisition(rootID, admission, lockFile, options, true, fmt.Errorf("close persistent state root: %w", err))
	}
	rootOpen = false

	return &stateLease{
		file:      lockFile,
		rootID:    rootID,
		admission: admission,
		options:   options,
	}, nil
}

func stateLeaseIdentity(info os.FileInfo) (stateLeaseRootID, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return stateLeaseRootID{}, fmt.Errorf("device and inode metadata is unavailable")
	}
	return stateLeaseRootID{device: uint64(stat.Dev), inode: uint64(stat.Ino)}, nil
}

func verifyStateLeasePath(rootFD int, opened os.FileInfo) error {
	var pathStat unix.Stat_t
	if err := unix.Fstatat(rootFD, stateLeaseFilename, &pathStat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return fmt.Errorf("revalidate persistent state lease: %w", err)
	}
	openedID, err := stateLeaseIdentity(opened)
	if err != nil {
		return fmt.Errorf("identify persistent state lease: %w", err)
	}
	if openedID.device != uint64(pathStat.Dev) || openedID.inode != uint64(pathStat.Ino) {
		return fmt.Errorf("persistent state lease path was replaced")
	}
	return nil
}
