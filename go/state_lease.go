package tailscale

import (
	"errors"
	"fmt"
	"os"
	"sync"
)

const stateLeaseFilename = ".tailscale-state.lock"

// ErrStateLeaseBusy means another owner currently holds the persistent-state
// lease. Acquisition is deliberately nonblocking; callers may retry only as
// part of their bounded lifecycle operation.
var ErrStateLeaseBusy = errors.New("persistent state lease busy")

type stateLeaseBusyError struct {
	Root string
}

func (err *stateLeaseBusyError) Error() string {
	if err == nil || err.Root == "" {
		return ErrStateLeaseBusy.Error()
	}
	return fmt.Sprintf("%s for %q", ErrStateLeaseBusy, err.Root)
}

func (*stateLeaseBusyError) Unwrap() error { return ErrStateLeaseBusy }

var errStateLeasePoisoned = errors.New("persistent state lease admission poisoned")

type stateLeaseRootID struct {
	device uint64
	inode  uint64
}

type stateLeaseAdmission struct {
	root     string
	poisoned error
}

var stateLeaseAdmissions = struct {
	sync.Mutex
	byRoot map[stateLeaseRootID]*stateLeaseAdmission
}{
	byRoot: make(map[stateLeaseRootID]*stateLeaseAdmission),
}

type stateLeaseTestHooks struct {
	lock      func(fd int) error
	unlock    func(fd int) error
	close     func(file *os.File) error
	closeRoot func(file *os.File) error
}

type stateLeaseOptions struct {
	stateLeaseTestHooks
	expectedRoot    os.FileInfo
	validateRelease bool
}

type stateLeaseOption func(*stateLeaseOptions)

// withStateLeaseTestHooks supplies syscall failure seams without exposing
// lock implementation choices to production callers. Nil hooks retain the
// platform defaults.
func withStateLeaseTestHooks(hooks stateLeaseTestHooks) stateLeaseOption {
	return func(options *stateLeaseOptions) {
		if hooks.lock != nil {
			options.lock = hooks.lock
		}
		if hooks.unlock != nil {
			options.unlock = hooks.unlock
		}
		if hooks.close != nil {
			options.close = hooks.close
		}
		if hooks.closeRoot != nil {
			options.closeRoot = hooks.closeRoot
		}
	}
}

// withExpectedStateLeaseRoot binds acquisition to Configure's frozen root
// inode instead of trusting only the lexical path at open time.
func withExpectedStateLeaseRoot(info os.FileInfo) stateLeaseOption {
	return func(options *stateLeaseOptions) {
		options.expectedRoot = info
	}
}

// withoutStateLeaseReleasePathValidation is reserved for package-owned
// scratch roots that are deliberately removed while their live lease remains
// held. Persistent roots retain release-time identity validation.
func withoutStateLeaseReleasePathValidation() stateLeaseOption {
	return func(options *stateLeaseOptions) {
		options.validateRelease = false
	}
}

// stateLease owns both one process-local root admission and one OS advisory
// lock. The verified root and lock descriptors stay open for the lease
// lifetime so every lexical filesystem operation can be bounded by an identity
// check against the exact root inode that was admitted.
type stateLease struct {
	mu sync.Mutex

	file      *os.File
	root      *os.File
	rootPath  string
	rootID    stateLeaseRootID
	admission *stateLeaseAdmission
	options   stateLeaseOptions

	released   bool
	releaseErr error
}

// Release relinquishes the OS lease and then its process-local admission. It
// is safe to call more than once or concurrently. Any uncertain unlock/close
// outcome permanently poisons this root's process-local admission.
func (lease *stateLease) Release() error {
	if lease == nil {
		return nil
	}

	lease.mu.Lock()
	defer lease.mu.Unlock()
	if lease.released {
		return lease.releaseErr
	}
	var cleanupErr error
	if lease.options.validateRelease {
		if err := lease.validatePathsLocked(); err != nil {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("validate persistent state lease before release: %w", err))
		}
	}
	lease.released = true
	if err := lease.options.unlock(int(lease.file.Fd())); err != nil {
		cleanupErr = errors.Join(cleanupErr, fmt.Errorf("unlock persistent state lease: %w", err))
	}
	if err := lease.options.close(lease.file); err != nil {
		cleanupErr = errors.Join(cleanupErr, fmt.Errorf("close persistent state lease: %w", err))
	}
	if err := lease.options.closeRoot(lease.root); err != nil {
		cleanupErr = errors.Join(cleanupErr, fmt.Errorf("close persistent state root: %w", err))
	}
	lease.releaseErr = cleanupErr
	finishStateLeaseAdmission(lease.rootID, lease.admission, cleanupErr)
	return lease.releaseErr
}

// validatePaths checks that both open descriptors still name the admitted
// objects and that the configured lexical root still resolves to the pinned
// root. Callers use it immediately before and after filesystem operations that
// still have to use paths rather than dirfd-relative syscalls.
func (lease *stateLease) validatePaths() error {
	if lease == nil {
		return fmt.Errorf("persistent state lease is unavailable")
	}
	lease.mu.Lock()
	defer lease.mu.Unlock()
	if lease.released {
		return fmt.Errorf("persistent state lease is released")
	}
	return lease.validatePathsLocked()
}

func reserveStateLeaseAdmission(root string, rootID stateLeaseRootID) (*stateLeaseAdmission, error) {
	stateLeaseAdmissions.Lock()
	defer stateLeaseAdmissions.Unlock()

	if existing := stateLeaseAdmissions.byRoot[rootID]; existing != nil {
		if existing.poisoned != nil {
			return nil, fmt.Errorf("%w for %q: %v", errStateLeasePoisoned, root, existing.poisoned)
		}
		return nil, &stateLeaseBusyError{Root: root}
	}
	admission := &stateLeaseAdmission{root: root}
	stateLeaseAdmissions.byRoot[rootID] = admission
	return admission, nil
}

func finishStateLeaseAdmission(rootID stateLeaseRootID, admission *stateLeaseAdmission, poison error) {
	stateLeaseAdmissions.Lock()
	defer stateLeaseAdmissions.Unlock()

	if stateLeaseAdmissions.byRoot[rootID] != admission {
		return
	}
	if poison != nil {
		admission.poisoned = poison
		return
	}
	delete(stateLeaseAdmissions.byRoot, rootID)
}

// abandonStateLeaseAcquisition closes a descriptor after acquisition failed.
// Once the OS lock succeeded, cleanup includes an unlock. Cleanup uncertainty
// poisons local admission even though the original acquisition also failed.
func abandonStateLeaseAcquisition(
	rootID stateLeaseRootID,
	admission *stateLeaseAdmission,
	file *os.File,
	root *os.File,
	options stateLeaseOptions,
	locked bool,
	acquireErr error,
) error {
	var cleanupErr error
	if locked && file != nil {
		if err := options.unlock(int(file.Fd())); err != nil {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("unlock persistent state lease: %w", err))
		}
	}
	if file != nil {
		if err := options.close(file); err != nil {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("close persistent state lease: %w", err))
		}
	}
	if root != nil {
		if err := options.closeRoot(root); err != nil {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("close persistent state root: %w", err))
		}
	}
	finishStateLeaseAdmission(rootID, admission, cleanupErr)
	if cleanupErr != nil {
		cleanupErr = fmt.Errorf("%w: %w", ErrRuntimeCleanupFailed, cleanupErr)
	}
	return errors.Join(acquireErr, cleanupErr)
}
