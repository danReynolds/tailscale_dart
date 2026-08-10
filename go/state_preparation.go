package tailscale

import (
	"errors"
	"fmt"
	"path/filepath"
	"sync"
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
// and either a future R4d runtime commit or token-qualified abandonment. R4c
// leaves this path latent: production DuneStart continues to use SQLite until
// the complete storage matrix switches atomically in R4d.
type persistentPreparation struct {
	token    uint64
	baseRoot string
	done     chan struct{}
	doneOnce sync.Once

	phaseMu sync.Mutex

	acquisitionSettled    bool
	abandoned             bool
	custodyActive         bool
	custodyWriteAttempted bool
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

func newPersistentPreparation(token uint64, baseRoot string) *persistentPreparation {
	return &persistentPreparation{
		token:    token,
		baseRoot: baseRoot,
		done:     make(chan struct{}),
	}
}

func (p *persistentPreparation) complete(err error) {
	p.phaseMu.Lock()
	p.terminalErr = err
	p.phaseMu.Unlock()
	p.doneOnce.Do(func() { close(p.done) })
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
		runtimes.mu.Unlock()
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if runtimes.persistentPreparation != nil || runtimes.candidate != nil ||
		runtimes.current != nil || runtimes.draining != nil || runtimes.logout != nil {
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
	if preparation.abandoned {
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if !preparation.acquisitionSettled || preparation.lease == nil {
		return fmt.Errorf("%w: state lease acquisition has not completed", ErrLifecycleBusy)
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
	if preparation.abandoned {
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
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
	if preparation.abandoned {
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
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
	if preparation.abandoned {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, preparation.token)
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

// createInitialPreparedEnvelope is intentionally unexported and unwired in
// R4c. It proves the barrier against R4b's real post-rename callback so R4d can
// later call the already-reviewed primitive without inventing new ordering.
func createInitialPreparedEnvelope(preparation *persistentPreparation) error {
	if preparation == nil {
		return fmt.Errorf("persistent preparation is nil")
	}
	path := filepath.Join(preparation.baseRoot, ownedStateSubdirectory, encryptedStateFileName)
	return runInitialEnvelopeWrite(preparation, func(key *[encryptedStateKeySize]byte, recordCommitted func()) (*encryptedStateStore, error) {
		options := defaultEncryptedStateStoreOptions()
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
	if p.envelopeOutcome == envelopeWriteInFlight {
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
	preparation.phaseMu.Unlock()
	if !abandoned || !custodyActive {
		return fmt.Errorf("%w: token %d does not own abandoned custody", ErrRuntimeStale, token)
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
			if runtimes.completedPreparations == nil {
				runtimes.completedPreparations = make(map[uint64]preparationOutcome)
			}
			runtimes.completedPreparations[preparation.token] = preparationOutcome{err: err}
		}
	}
	runtimes.mu.Unlock()
	preparation.complete(err)
	return err
}
