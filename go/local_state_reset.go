package tailscale

import (
	"errors"
	"fmt"
	"sync"
)

// LocalResetBeginResult describes the only caller-visible runtime transition
// that can occur before Keybay custody is changed.
type LocalResetBeginResult struct {
	Token   uint64 `json:"token"`
	Stopped bool   `json:"stopped"`
}

// localResetOperation retains the exact state lease across runtime teardown,
// durable marker creation, Keybay deletion, and package-state deletion.
type localResetOperation struct {
	token uint64

	phaseMu   sync.Mutex
	ready     bool
	finishing bool
	lease     *stateLease
	fs        *stateResetFilesystem
}

func newLocalResetOperation(token uint64) *localResetOperation {
	return &localResetOperation{token: token}
}

// BeginLocalReset establishes durable reset intent before the caller mutates
// Keybay. When a runtime is active, its already-held lease moves directly to
// this transaction before Server/Store teardown, leaving no unlock/relock gap.
func BeginLocalReset(token uint64) (result LocalResetBeginResult, err error) {
	result.Token = token
	if token == 0 {
		return result, fmt.Errorf("local reset token must be non-zero")
	}
	baseRoot, expectedRoot, err := configuredStateRootSnapshot()
	if err != nil {
		return result, err
	}

	op := newLocalResetOperation(token)
	var runtime *nodeRuntime
	runtimes.mu.Lock()
	if err := runtimes.cleanupAdmissionErrorLocked(); err != nil {
		runtimes.mu.Unlock()
		return result, err
	}
	if runtimes.reset != nil || runtimes.persistentPreparation != nil ||
		runtimes.candidate != nil || runtimes.draining != nil || runtimes.logout != nil {
		runtimes.mu.Unlock()
		return result, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	if runtime = runtimes.current; runtime != nil {
		if runtime.stateLease == nil {
			runtimes.mu.Unlock()
			return result, fmt.Errorf("%w: active runtime does not own its state lease", ErrRuntimeCleanupFailed)
		}
		op.lease = runtime.stateLease
		runtime.stateLease = nil
		runtimes.current = nil
		nodeEpoch.Add(1)
		result.Stopped = true
	}
	runtimes.reset = op
	runtimes.mu.Unlock()

	if runtime != nil {
		if closeErr := runtime.close(); closeErr != nil {
			failure := runtimes.recordCleanupFailure(token, closeErr)
			return result, failure
		}
	} else {
		lease, acquireErr := acquireStateLease(
			baseRoot,
			withExpectedStateLeaseRoot(expectedRoot),
		)
		if acquireErr != nil {
			return result, abortLocalResetBeforeCustody(op, acquireErr)
		}
		op.phaseMu.Lock()
		op.lease = lease
		op.phaseMu.Unlock()
	}

	resetFS, openErr := openStateResetFilesystem(baseRoot, expectedRoot)
	if openErr != nil {
		return result, abortLocalResetBeforeCustody(op, openErr)
	}
	op.phaseMu.Lock()
	op.fs = resetFS
	op.phaseMu.Unlock()
	if markerErr := resetFS.ensureDurableMarker(); markerErr != nil {
		return result, abortLocalResetBeforeCustody(op, markerErr)
	}

	op.phaseMu.Lock()
	op.ready = true
	op.phaseMu.Unlock()
	return result, nil
}

// FinishLocalReset commits package-state removal only after Dart confirms the
// exact Keybay DEK deletion. An unconfirmed delete deliberately leaves the
// durable marker so ordinary startup cannot guess at key/file coherence.
func FinishLocalReset(token uint64, custodyDeletionSucceeded bool) error {
	runtimes.mu.Lock()
	op := runtimes.reset
	runtimes.mu.Unlock()
	if op == nil || op.token != token {
		return fmt.Errorf("%w: local reset token %d is not current", ErrRuntimeStale, token)
	}

	op.phaseMu.Lock()
	if !op.ready || op.finishing {
		op.phaseMu.Unlock()
		return fmt.Errorf("%w: local reset token %d is not ready", ErrLifecycleBusy, token)
	}
	op.finishing = true
	resetFS := op.fs
	op.phaseMu.Unlock()

	var operationErr error
	if !custodyDeletionSucceeded {
		operationErr = fmt.Errorf("%w: Keybay deletion was not confirmed", ErrLocalResetIncomplete)
	} else if resetFS == nil {
		operationErr = fmt.Errorf("%w: reset filesystem is unavailable", ErrLocalResetIncomplete)
	} else {
		operationErr = resetFS.completeAfterCustodyDeletion()
	}
	return finishLocalResetOperation(op, operationErr)
}

func abortLocalResetBeforeCustody(op *localResetOperation, primary error) error {
	return finishLocalResetOperation(op, primary)
}

func finishLocalResetOperation(op *localResetOperation, primary error) error {
	if op == nil {
		return primary
	}
	op.phaseMu.Lock()
	resetFS := op.fs
	op.fs = nil
	lease := op.lease
	op.lease = nil
	op.phaseMu.Unlock()

	var cleanupErr error
	if resetFS != nil {
		cleanupErr = errors.Join(cleanupErr, resetFS.Close())
	}
	if lease != nil {
		cleanupErr = errors.Join(cleanupErr, lease.Release())
	}
	if cleanupErr != nil {
		cleanupErr = runtimes.recordCleanupFailure(op.token, cleanupErr)
	}
	err := errors.Join(primary, cleanupErr)

	runtimes.mu.Lock()
	if runtimes.reset == op {
		runtimes.reset = nil
	}
	runtimes.mu.Unlock()
	return err
}
