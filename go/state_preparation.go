package tailscale

import (
	"errors"
	"fmt"
	"path/filepath"
	"sync"

	"tailscale.com/util/mak"
)

// ErrInvalidStateKey means the supplied StateStore data-encryption key was
// not exactly the fixed binary size required by the encrypted envelope.
var ErrInvalidStateKey = errors.New("invalid Tailscale state encryption key")

// CustodyDisposition tells the caller-isolate supervisor how to settle a
// possibly late Keybay operation after native preparation was abandoned.
// Admission and the OS lease remain held until FinishCustody succeeds.
type CustodyDisposition string

const (
	CustodyDispositionNone                 CustodyDisposition = "none"
	CustodyDispositionCompensateKey        CustodyDisposition = "compensateKey"
	CustodyDispositionPreserveCoherentPair CustodyDisposition = "preserveCoherentPair"
)

type envelopeWriteOutcome uint8

const (
	envelopeWriteNone envelopeWriteOutcome = iota
	envelopeWriteInFlight
	envelopeWriteNotCommitted
	envelopeWriteCommitted
)

// persistentPreparation is the native owner between secure-state admission
// and either runtime adoption, a completed idle probe, or token-qualified
// abandonment.
type persistentPreparation struct {
	token    uint64
	baseRoot string
	done     chan struct{}
	doneOnce sync.Once

	phaseMu sync.Mutex

	acquisitionSettled    bool
	abandoned             bool
	custodyActive         bool
	custodyCompleted      bool
	custodyWriteAttempted bool
	layoutInspected       bool
	layout                PersistentStateLayout
	custodyResolved       bool
	custodyDEKPresent     bool
	custodyResolveErr     error
	action                PersistentPreparationAction
	storeEmpty            bool
	statePrepareAttempted bool
	operationInFlight     bool
	operationDone         chan struct{}
	finishing             bool
	adopted               bool
	envelopeOutcome       envelopeWriteOutcome
	writeDone             chan struct{}

	lease       *stateLease
	dekSupplied bool
	stagedDEK   [encryptedStateKeySize]byte
	store       *encryptedStateStore
	terminalErr error

	custodyCleanupOnce sync.Once
	custodyCleanupErr  error
	cleanupOnce        sync.Once
	cleanupErr         error
}

// requireLiveLocked is the shared liveness guard for every exported operation
// on a preparation. Callers must hold phaseMu. Abandoned wins over terminating
// so rescue evidence is never masked, and one shared guard means a future
// phase flag cannot be silently omitted at a single entry point.
func (p *persistentPreparation) requireLiveLocked() error {
	if p.abandoned {
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, p.token)
	}
	if p.finishing || p.adopted {
		return fmt.Errorf("%w: preparation token %d is terminating", ErrRuntimeStale, p.token)
	}
	return nil
}

func (p *persistentPreparation) beginOperation(name string) (func() error, error) {
	p.phaseMu.Lock()
	if err := p.requireLiveLocked(); err != nil {
		p.phaseMu.Unlock()
		return nil, err
	}
	if !p.acquisitionSettled || p.lease == nil {
		p.phaseMu.Unlock()
		return nil, fmt.Errorf("%w: state lease acquisition has not completed", ErrLifecycleBusy)
	}
	if p.operationInFlight {
		p.phaseMu.Unlock()
		return nil, fmt.Errorf("%w: another state preparation operation is active", ErrLifecycleBusy)
	}
	lease := p.lease
	if err := lease.validatePaths(); err != nil {
		p.phaseMu.Unlock()
		return nil, fmt.Errorf("%s lease boundary: %w", name, err)
	}
	done := make(chan struct{})
	p.operationInFlight = true
	p.operationDone = done
	p.phaseMu.Unlock()

	var once sync.Once
	var finishErr error
	return func() error {
		once.Do(func() {
			if err := lease.validatePaths(); err != nil {
				finishErr = fmt.Errorf("%s completion lease boundary: %w", name, err)
			}
			p.phaseMu.Lock()
			if p.operationDone == done {
				p.operationInFlight = false
				p.operationDone = nil
				close(done)
			}
			p.phaseMu.Unlock()
		})
		return finishErr
	}, nil
}

func newPersistentPreparation(token uint64, baseRoot string) *persistentPreparation {
	return &persistentPreparation{
		token:    token,
		baseRoot: baseRoot,
		done:     make(chan struct{}),
	}
}

func (p *persistentPreparation) complete(err error) {
	p.doneOnce.Do(func() {
		p.phaseMu.Lock()
		p.terminalErr = err
		close(p.done)
		p.phaseMu.Unlock()
	})
}

func (p *persistentPreparation) result() error {
	p.phaseMu.Lock()
	defer p.phaseMu.Unlock()
	return p.terminalErr
}

func (p *persistentPreparation) cleanupCustodyResources() error {
	p.custodyCleanupOnce.Do(func() {
		p.phaseMu.Lock()
		store := p.store
		p.store = nil
		wipeBytes(p.stagedDEK[:])
		p.dekSupplied = false
		p.phaseMu.Unlock()

		if store != nil {
			p.custodyCleanupErr = errors.Join(p.custodyCleanupErr, store.Close())
		}
	})
	return p.custodyCleanupErr
}

func (p *persistentPreparation) cleanupResources() error {
	p.cleanupOnce.Do(func() {
		p.cleanupErr = errors.Join(p.cleanupErr, p.cleanupCustodyResources())
		p.phaseMu.Lock()
		lease := p.lease
		p.lease = nil
		p.phaseMu.Unlock()
		if lease != nil {
			p.cleanupErr = errors.Join(p.cleanupErr, lease.Release())
		}
	})
	return p.cleanupErr
}

// BeginPersistentPreparation binds the configured canonical state root and
// its process/cross-process lease to a supervisor-created token. It performs no
// secure-state probe, Keybay operation, StateStore creation, or SQLite access.
func BeginPersistentPreparation(token uint64) error {
	if token == 0 {
		return fmt.Errorf("persistent preparation token must be non-zero")
	}
	baseRoot, expectedRoot, err := configuredStateRootSnapshot()
	if err != nil {
		return err
	}

	preparation := newPersistentPreparation(token, baseRoot)
	runtimes.mu.Lock()
	if err := runtimes.cleanupAdmissionErrorLocked(); err != nil {
		runtimes.mu.Unlock()
		return err
	}
	if _, abandoned := runtimes.abandonedTokens[token]; abandoned {
		// This Begin call consumed the pre-dispatch tombstone. It cannot proceed
		// to any later phase for the same token after returning this error.
		delete(runtimes.abandonedTokens, token)
		runtimes.mu.Unlock()
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if runtimes.persistentPreparation != nil || runtimes.candidate != nil ||
		runtimes.current != nil || runtimes.draining != nil || runtimes.logout != nil ||
		runtimes.reset != nil {
		runtimes.mu.Unlock()
		return fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	runtimes.persistentPreparation = preparation
	runtimes.mu.Unlock()

	lease, acquireErr := acquireStateLease(
		baseRoot,
		withExpectedStateLeaseRoot(expectedRoot),
	)

	runtimes.mu.Lock()
	preparation.phaseMu.Lock()
	preparation.acquisitionSettled = true
	preparation.lease = lease
	abandoned := preparation.abandoned
	preparation.phaseMu.Unlock()
	stillCurrent := runtimes.persistentPreparation == preparation
	runtimes.mu.Unlock()

	if acquireErr != nil {
		if stillCurrent {
			return finishPersistentPreparation(preparation, acquireErr)
		}
		return acquireErr
	}
	if !stillCurrent || abandoned {
		cleanupErr := finishPersistentPreparation(preparation, nil)
		return errors.Join(
			fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token),
			cleanupErr,
		)
	}
	return nil
}

func persistentPreparationForToken(token uint64) (*persistentPreparation, error) {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	preparation := runtimes.persistentPreparation
	if preparation == nil || preparation.token != token {
		return nil, fmt.Errorf("%w: persistent preparation token %d is not current", ErrRuntimeStale, token)
	}
	return preparation, nil
}

// MarkCustodyActive must run before the caller awaits any Keybay operation.
func MarkCustodyActive(token uint64) error {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return err
	}
	if !preparation.acquisitionSettled || preparation.lease == nil {
		return fmt.Errorf("%w: state lease acquisition has not completed", ErrLifecycleBusy)
	}
	if preparation.custodyActive || preparation.custodyCompleted {
		return fmt.Errorf("%w: state custody was already activated for token %d", ErrLifecycleBusy, token)
	}
	preparation.custodyActive = true
	return nil
}

// MarkCustodyWriteAttempted records the possibly-committed boundary before a
// fresh-key Keybay write is invoked. A returned Keybay error cannot clear it.
func MarkCustodyWriteAttempted(token uint64) error {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return err
	}
	if !preparation.custodyActive {
		return fmt.Errorf("custody is not active for preparation token %d", token)
	}
	preparation.custodyWriteAttempted = true
	return nil
}

// SupplyPreparedDEK accepts only raw binary key bytes. The caller owns and
// wipes its input; native retains one mutable staged copy until it moves into
// an encrypted Store or preparation is finished.
func SupplyPreparedDEK(token uint64, raw []byte) error {
	if len(raw) != encryptedStateKeySize {
		return fmt.Errorf("%w: got %d bytes, want %d", ErrInvalidStateKey, len(raw), encryptedStateKeySize)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return err
	}
	if !preparation.custodyActive {
		return fmt.Errorf("custody is not active for preparation token %d", token)
	}
	if preparation.dekSupplied {
		return fmt.Errorf("state encryption key was already supplied for token %d", token)
	}
	if preparation.envelopeOutcome != envelopeWriteNone {
		return fmt.Errorf("state encryption key was already consumed for token %d", token)
	}
	copy(preparation.stagedDEK[:], raw)
	preparation.dekSupplied = true
	return nil
}

// runInitialEnvelopeWrite supplies the explicit rename-result barrier shared
// by fresh provisioning and abandonment. R4d invokes this primitive only after
// its secure-state classifier has selected the fresh-enrollment row.
func runInitialEnvelopeWrite(
	preparation *persistentPreparation,
	write func(key *[encryptedStateKeySize]byte, recordCommitted func()) (*encryptedStateStore, error),
) error {
	if preparation == nil || write == nil {
		return fmt.Errorf("invalid initial encrypted-envelope write")
	}

	preparation.phaseMu.Lock()
	if err := preparation.requireLiveLocked(); err != nil {
		preparation.phaseMu.Unlock()
		return err
	}
	if !preparation.custodyWriteAttempted || !preparation.dekSupplied {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("fresh encrypted-envelope write requires committed custody and a supplied key")
	}
	if preparation.envelopeOutcome != envelopeWriteNone {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("initial encrypted-envelope write already started")
	}
	writeDone := make(chan struct{})
	key := preparation.stagedDEK
	wipeBytes(preparation.stagedDEK[:])
	preparation.dekSupplied = false
	preparation.envelopeOutcome = envelopeWriteInFlight
	preparation.writeDone = writeDone
	preparation.phaseMu.Unlock()
	defer wipeBytes(key[:])

	var commitOnce sync.Once
	recordCommitted := func() {
		commitOnce.Do(func() {
			preparation.phaseMu.Lock()
			if preparation.envelopeOutcome == envelopeWriteInFlight {
				preparation.envelopeOutcome = envelopeWriteCommitted
			}
			preparation.phaseMu.Unlock()
		})
	}
	store, writeErr := write(&key, recordCommitted)

	preparation.phaseMu.Lock()
	if preparation.envelopeOutcome == envelopeWriteInFlight {
		preparation.envelopeOutcome = envelopeWriteNotCommitted
	}
	committed := preparation.envelopeOutcome == envelopeWriteCommitted
	if committed && store != nil {
		preparation.store = store
		store = nil
	}
	close(writeDone)
	preparation.phaseMu.Unlock()

	if store != nil {
		writeErr = errors.Join(writeErr, store.Close())
	}
	if writeErr == nil && !committed {
		return fmt.Errorf("initial encrypted-envelope write returned without recording its commit")
	}
	return writeErr
}

// createInitialPreparedEnvelope binds fresh provisioning to the encrypted
// store's post-rename commit callback so abandonment can preserve or compensate
// the Keybay/file pair without guessing.
func createInitialPreparedEnvelope(preparation *persistentPreparation) error {
	if preparation == nil {
		return fmt.Errorf("persistent preparation is nil")
	}
	path := filepath.Join(preparation.baseRoot, ownedStateSubdirectory, encryptedStateFileName)
	return runInitialEnvelopeWrite(preparation, func(key *[encryptedStateKeySize]byte, recordCommitted func()) (*encryptedStateStore, error) {
		options := defaultEncryptedStateStoreOptions()
		options.validateRootPath = preparation.lease.validatePaths
		options.recordInitialCommit = recordCommitted
		return createEncryptedStateStoreWithOptions(path, *key, options)
	})
}

func (p *persistentPreparation) abandonDisposition() (bool, <-chan struct{}, CustodyDisposition) {
	p.phaseMu.Lock()
	defer p.phaseMu.Unlock()
	p.abandoned = true
	if !p.acquisitionSettled {
		return false, nil, CustodyDispositionNone
	}
	var wait <-chan struct{}
	if p.operationInFlight {
		wait = p.operationDone
	} else if p.envelopeOutcome == envelopeWriteInFlight {
		wait = p.writeDone
	}
	return p.custodyActive, wait, p.custodyDispositionLocked()
}

func (p *persistentPreparation) custodyDisposition() CustodyDisposition {
	p.phaseMu.Lock()
	defer p.phaseMu.Unlock()
	return p.custodyDispositionLocked()
}

func (p *persistentPreparation) custodyDispositionLocked() CustodyDisposition {
	if p.envelopeOutcome == envelopeWriteCommitted {
		return CustodyDispositionPreserveCoherentPair
	}
	if p.custodyWriteAttempted {
		return CustodyDispositionCompensateKey
	}
	return CustodyDispositionNone
}

// FinishCustody releases an abandoned preparation only after the caller has
// joined the non-cancellable Keybay Future and performed any exact-entry
// compensation. A failed compensation deliberately poisons and retains native
// admission until process restart.
func FinishCustody(token uint64, cleanupSucceeded bool) error {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	abandoned := preparation.abandoned
	custodyActive := preparation.custodyActive
	operationInFlight := preparation.operationInFlight
	writeInFlight := preparation.envelopeOutcome == envelopeWriteInFlight
	preparation.phaseMu.Unlock()
	if !abandoned || !custodyActive {
		return fmt.Errorf("%w: token %d does not own abandoned custody", ErrRuntimeStale, token)
	}
	if operationInFlight || writeInFlight {
		return fmt.Errorf("%w: state custody operation is still active for token %d", ErrLifecycleBusy, token)
	}
	if !cleanupSucceeded {
		// Retain the lease/admission, but do not retain key material merely
		// because caller-side compensation failed. Closing the Store preserves
		// any committed envelope while wiping its in-memory key copy.
		cleanupErr := preparation.cleanupCustodyResources()
		failure := errors.Join(
			fmt.Errorf("%w: Keybay custody compensation was not confirmed for token %d", ErrRuntimeCleanupFailed, token),
			cleanupErr,
		)
		runtimes.recordCleanupFailure(token, failure)
		return failure
	}
	return finishPersistentPreparation(preparation, nil)
}

func finishPersistentPreparation(preparation *persistentPreparation, primary error) error {
	if preparation == nil {
		return primary
	}
	preparation.phaseMu.Lock()
	if preparation.adopted {
		preparation.phaseMu.Unlock()
		return errors.Join(primary, fmt.Errorf("%w: preparation token %d was adopted", ErrRuntimeStale, preparation.token))
	}
	if preparation.finishing {
		done := preparation.done
		preparation.phaseMu.Unlock()
		<-done
		return errors.Join(primary, preparation.result())
	}
	preparation.finishing = true
	preparation.phaseMu.Unlock()
	return finishClaimedPersistentPreparation(preparation, primary)
}

func finishClaimedPersistentPreparation(preparation *persistentPreparation, primary error) error {
	cleanupErr := preparation.cleanupResources()
	err := errors.Join(primary, cleanupErr)
	if cleanupErr != nil {
		err = errors.Join(primary, runtimes.recordCleanupFailure(preparation.token, cleanupErr))
	} else if errors.Is(primary, ErrRuntimeCleanupFailed) {
		// Lease acquisition can fail after uncertain descriptor cleanup. Mirror
		// the lease's local poison in controller admission so every later
		// lifecycle operation returns the stable typed cleanup failure.
		_ = runtimes.recordCleanupFailure(preparation.token, primary)
	}
	preparation.phaseMu.Lock()
	abandoned := preparation.abandoned
	preparation.phaseMu.Unlock()

	runtimes.mu.Lock()
	if runtimes.persistentPreparation == preparation {
		runtimes.persistentPreparation = nil
		if abandoned {
			mak.Set(&runtimes.completedPreparations, preparation.token, preparationOutcome{err: err})
		}
	}
	runtimes.mu.Unlock()
	preparation.complete(err)
	return err
}
