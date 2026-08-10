package tailscale

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	ephemeralStateScratchPrefix     = "tailscale-dart-ephemeral-"
	ephemeralStateScratchMinimumAge = 24 * time.Hour
)

// ErrEphemeralPersistentStateOccupied means ephemeral startup found
// filesystem-visible state in the package-owned persistent subtree. Ephemeral
// mode must never inspect Keybay to refine this conservative result.
var ErrEphemeralPersistentStateOccupied = errors.New("persistent Tailscale state prevents ephemeral startup")

// validateEphemeralPersistentOccupancy performs the filesystem-only admission
// check for ephemeral startup. The caller must already hold the base-root
// state lease, which serializes this check with persistent startup and reset.
// An absent or exactly empty package subtree is allowed. Any reset marker,
// symlink, non-directory, unreadable path, or directory entry fails closed.
func validateEphemeralPersistentOccupancy(baseRoot string) error {
	if strings.TrimSpace(baseRoot) == "" {
		return fmt.Errorf("persistent state root is empty")
	}
	baseRoot = filepath.Clean(baseRoot)

	markerPath := filepath.Join(baseRoot, stateResetMarkerFilename)
	if _, err := os.Lstat(markerPath); err == nil {
		return fmt.Errorf("%w: marker %q is present", ErrLocalResetIncomplete, markerPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: inspect reset marker: %v", ErrLocalResetIncomplete, err)
	}

	stateDir := filepath.Join(baseRoot, ownedStateSubdirectory)
	info, err := os.Lstat(stateDir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("%w: inspect package subtree: %v", ErrEphemeralPersistentStateOccupied, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("%w: package subtree is not a real directory", ErrEphemeralPersistentStateOccupied)
	}

	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return fmt.Errorf("%w: list package subtree: %v", ErrEphemeralPersistentStateOccupied, err)
	}
	if len(entries) != 0 {
		return fmt.Errorf(
			"%w: package subtree contains %d entries",
			ErrEphemeralPersistentStateOccupied,
			len(entries),
		)
	}
	return nil
}

// ephemeralStateScratch owns the writable tsnet runtime directory and its
// nonblocking live lease. Close removes only the originally-created directory,
// while the lease is still held, and then releases the lease.
type ephemeralStateScratch struct {
	mu sync.Mutex

	parent   string
	path     string
	rootInfo os.FileInfo
	lease    *stateLease

	closed   bool
	closeErr error
}

// ephemeralScratchParent prefers the host-supplied platform temporary
// directory (see SetEphemeralScratchParent) and falls back to os.TempDir()
// for direct Go callers.
func ephemeralScratchParent() string {
	if parent := configuredEphemeralScratchParent(); parent != "" {
		return parent
	}
	return os.TempDir()
}

func createEphemeralStateScratch() (*ephemeralStateScratch, error) {
	return createEphemeralStateScratchIn(ephemeralScratchParent())
}

func createEphemeralStateScratchIn(parent string) (*ephemeralStateScratch, error) {
	if strings.TrimSpace(parent) == "" {
		return nil, fmt.Errorf("ephemeral scratch parent is empty")
	}
	parent = filepath.Clean(parent)
	path, err := os.MkdirTemp(parent, ephemeralStateScratchPrefix)
	if err != nil {
		return nil, fmt.Errorf("create ephemeral state scratch: %w", err)
	}

	info, verifyErr := verifyEphemeralStateScratchRoot(path, nil)
	if verifyErr != nil {
		cleanupErr := removeEphemeralStateScratchRoot(parent, path, nil)
		return nil, errors.Join(verifyErr, cleanupErr)
	}
	lease, err := acquireStateLease(
		path,
		withExpectedStateLeaseRoot(info),
		withoutStateLeaseReleasePathValidation(),
	)
	if err != nil {
		cleanupErr := removeEphemeralStateScratchRoot(parent, path, info)
		return nil, errors.Join(fmt.Errorf("acquire ephemeral state live lease: %w", err), cleanupErr)
	}
	return &ephemeralStateScratch{
		parent:   parent,
		path:     path,
		rootInfo: info,
		lease:    lease,
	}, nil
}

func (scratch *ephemeralStateScratch) directory() string {
	if scratch == nil {
		return ""
	}
	scratch.mu.Lock()
	defer scratch.mu.Unlock()
	return scratch.path
}

// Close is idempotent and safe for concurrent callers. Deletion is attempted
// before lease release so an old scratch directory can never be reaped while
// its runtime is still live.
func (scratch *ephemeralStateScratch) Close() error {
	if scratch == nil {
		return nil
	}
	scratch.mu.Lock()
	defer scratch.mu.Unlock()
	if scratch.closed {
		return scratch.closeErr
	}
	scratch.closed = true

	removeErr := removeEphemeralStateScratchRoot(scratch.parent, scratch.path, scratch.rootInfo)
	releaseErr := scratch.lease.Release()
	scratch.lease = nil
	scratch.closeErr = errors.Join(removeErr, releaseErr)
	return scratch.closeErr
}

// sweepStaleEphemeralStateScratch removes only old, owner-only package scratch
// directories whose nonblocking live lease can be acquired. It is intentionally
// best-effort with respect to untrusted or live candidates: unsafe names,
// symlinks, broad modes, young directories, and busy leases are skipped.
func sweepStaleEphemeralStateScratch() (int, error) {
	return sweepStaleEphemeralStateScratchIn(
		ephemeralScratchParent(),
		time.Now(),
		ephemeralStateScratchMinimumAge,
	)
}

func sweepStaleEphemeralStateScratchIn(parent string, now time.Time, minimumAge time.Duration) (int, error) {
	if strings.TrimSpace(parent) == "" {
		return 0, fmt.Errorf("ephemeral scratch parent is empty")
	}
	if minimumAge <= 0 {
		return 0, fmt.Errorf("ephemeral scratch minimum age must be positive")
	}
	parent = filepath.Clean(parent)
	entries, err := os.ReadDir(parent)
	if err != nil {
		return 0, fmt.Errorf("list ephemeral scratch parent: %w", err)
	}

	cutoff := now.Add(-minimumAge)
	removed := 0
	var sweepErr error
	for _, entry := range entries {
		name := entry.Name()
		if !isEphemeralStateScratchName(name) {
			continue
		}
		path := filepath.Join(parent, name)
		info, err := os.Lstat(path)
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				sweepErr = errors.Join(sweepErr, fmt.Errorf("inspect stale ephemeral scratch %q: %w", path, err))
			}
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || info.Mode().Perm() != 0o700 {
			continue
		}
		if err := verifyCurrentUserOwns(info); err != nil {
			continue
		}
		if info.ModTime().After(cutoff) {
			continue
		}

		lease, err := acquireStateLease(
			path,
			withExpectedStateLeaseRoot(info),
			withoutStateLeaseReleasePathValidation(),
		)
		if errors.Is(err, ErrStateLeaseBusy) {
			continue
		}
		if err != nil {
			sweepErr = errors.Join(sweepErr, fmt.Errorf("acquire stale ephemeral scratch %q: %w", path, err))
			continue
		}
		scratch := &ephemeralStateScratch{
			parent:   parent,
			path:     path,
			rootInfo: info,
			lease:    lease,
		}
		if err := scratch.Close(); err != nil {
			sweepErr = errors.Join(sweepErr, fmt.Errorf("remove stale ephemeral scratch %q: %w", path, err))
			continue
		}
		removed++
	}
	return removed, sweepErr
}

func isEphemeralStateScratchName(name string) bool {
	return strings.HasPrefix(name, ephemeralStateScratchPrefix) && len(name) > len(ephemeralStateScratchPrefix)
}

func verifyEphemeralStateScratchRoot(path string, expected os.FileInfo) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect ephemeral state scratch: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, fmt.Errorf("ephemeral state scratch is not a real directory")
	}
	if expected != nil && !os.SameFile(expected, info) {
		return nil, fmt.Errorf("ephemeral state scratch path was replaced")
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		return nil, fmt.Errorf("verify ephemeral state scratch ownership: %w", err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		return nil, fmt.Errorf("ephemeral state scratch permissions are %04o, want 0700", got)
	}
	return info, nil
}

func removeEphemeralStateScratchRoot(parent, path string, expected os.FileInfo) error {
	if filepath.Clean(filepath.Dir(path)) != filepath.Clean(parent) ||
		!isEphemeralStateScratchName(filepath.Base(path)) {
		return fmt.Errorf("refuse to remove non-package ephemeral scratch %q", path)
	}
	if _, err := verifyEphemeralStateScratchRoot(path, expected); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if expected == nil {
				return nil
			}
			return fmt.Errorf("ephemeral state scratch disappeared before cleanup: %w", err)
		}
		return err
	}

	// Move the exact inode out of its active name before unlinking the lock
	// file. Otherwise another sweeper could observe the old directory between
	// lock-file deletion and directory deletion and acquire a newly-created lock
	// inode. The renamed path keeps the package prefix for crash recovery, while
	// the fresh mtime keeps other sweepers away from an in-progress cleanup.
	cleanupPath := path + "-cleanup"
	if _, err := os.Lstat(cleanupPath); err == nil {
		return fmt.Errorf("refuse to replace existing ephemeral cleanup path %q", cleanupPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect ephemeral cleanup path: %w", err)
	}
	if err := os.Rename(path, cleanupPath); err != nil {
		return fmt.Errorf("isolate ephemeral state scratch for removal: %w", err)
	}
	if _, err := verifyEphemeralStateScratchRoot(cleanupPath, expected); err != nil {
		return fmt.Errorf("verify isolated ephemeral state scratch: %w", err)
	}
	now := time.Now()
	if err := os.Chtimes(cleanupPath, now, now); err != nil {
		return fmt.Errorf("refresh isolated ephemeral state scratch age: %w", err)
	}
	if err := os.RemoveAll(cleanupPath); err != nil {
		return fmt.Errorf("remove ephemeral state scratch: %w", err)
	}
	if _, err := os.Lstat(cleanupPath); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			err = fmt.Errorf("path still exists")
		}
		return fmt.Errorf("verify ephemeral state scratch removal: %w", err)
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			err = fmt.Errorf("active path was recreated")
		}
		return fmt.Errorf("verify active ephemeral scratch remains absent: %w", err)
	}
	return nil
}
