package tailscale

import (
	"errors"
	"fmt"
	"path/filepath"
)

var (
	// ErrMissingStateDEK means an encrypted envelope exists but its exact
	// installation key is absent from Keybay. Starting fresh would destroy the
	// only local recovery evidence, so persistent operations fail closed.
	ErrMissingStateDEK = errors.New("encrypted Tailscale state key is missing")

	// ErrOrphanedStateDEK means Keybay contains a DEK while the corresponding
	// encrypted envelope is absent. The package never guesses which side is
	// authoritative and requires explicit local forget.
	ErrOrphanedStateDEK = errors.New("orphaned Tailscale state encryption key")
)

// PersistentPreparationAction is the native-enforced result of combining the
// keyless filesystem layout with Keybay presence. Dart may carry this value,
// but cannot use it to change which open/create transition native permits.
type PersistentPreparationAction string

const (
	PersistentPreparationProvision PersistentPreparationAction = "provision"
	PersistentPreparationOpen      PersistentPreparationAction = "open"
)

// InspectPersistentPreparation performs the keyless half of the secure-state
// matrix while the exact token retains the configured root lease.
func InspectPersistentPreparation(token uint64) (layout PersistentStateLayout, resultErr error) {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return "", err
	}
	finish, err := preparation.beginOperation("inspect persistent state")
	if err != nil {
		return "", err
	}
	defer func() {
		resultErr = errors.Join(resultErr, finish())
	}()

	layout, err = inspectPersistentStateLayout(preparation.baseRoot)
	if err != nil {
		return "", err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return "", err
	}
	if preparation.layoutInspected && preparation.layout != layout {
		return "", fmt.Errorf("%w: persistent layout changed during preparation", ErrUnexpectedStateResidue)
	}
	preparation.layout = layout
	preparation.layoutInspected = true
	return layout, nil
}

// ResolvePersistentCustody combines key presence with the already-recorded
// filesystem class. Missing/orphaned rows are terminal typed errors; neither
// can be converted into fresh provisioning by a later Dart call.
func ResolvePersistentCustody(token uint64, dekPresent bool) (PersistentPreparationAction, error) {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return "", err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return "", err
	}
	if !preparation.custodyActive || preparation.custodyCompleted {
		return "", fmt.Errorf("state custody is not active for preparation token %d", token)
	}
	if !preparation.layoutInspected {
		return "", fmt.Errorf("persistent layout was not inspected for token %d", token)
	}
	if preparation.custodyResolved {
		if preparation.custodyDEKPresent != dekPresent {
			return "", fmt.Errorf("custody presence changed for preparation token %d", token)
		}
		return preparation.action, preparation.custodyResolveErr
	}

	preparation.custodyResolved = true
	preparation.custodyDEKPresent = dekPresent
	switch preparation.layout {
	case PersistentStateLayoutAbsent:
		if dekPresent {
			preparation.custodyResolveErr = ErrOrphanedStateDEK
			return "", preparation.custodyResolveErr
		}
		preparation.action = PersistentPreparationProvision
	case PersistentStateLayoutEncrypted:
		if !dekPresent {
			preparation.custodyResolveErr = ErrMissingStateDEK
			return "", preparation.custodyResolveErr
		}
		preparation.action = PersistentPreparationOpen
	default:
		return "", fmt.Errorf("unknown persistent layout %q", preparation.layout)
	}
	return preparation.action, nil
}

// PreparePersistentState consumes the staged DEK exactly once and either
// authenticates the existing envelope or creates the initial empty envelope.
// The returned emptiness excludes package-owned runtime metadata.
func PreparePersistentState(token uint64) (empty bool, resultErr error) {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return false, err
	}
	finish, err := preparation.beginOperation("prepare persistent state")
	if err != nil {
		return false, err
	}
	defer func() {
		resultErr = errors.Join(resultErr, finish())
	}()

	preparation.phaseMu.Lock()
	if !preparation.custodyActive || preparation.custodyCompleted {
		preparation.phaseMu.Unlock()
		return false, fmt.Errorf("state custody is not active for preparation token %d", token)
	}
	if !preparation.custodyResolved || preparation.action == "" {
		preparation.phaseMu.Unlock()
		return false, fmt.Errorf("state custody was not resolved for preparation token %d", token)
	}
	if preparation.store != nil {
		empty := preparation.storeEmpty
		preparation.phaseMu.Unlock()
		return empty, nil
	}
	if preparation.statePrepareAttempted {
		preparation.phaseMu.Unlock()
		return false, fmt.Errorf("persistent StateStore preparation was already attempted")
	}
	preparation.statePrepareAttempted = true
	action := preparation.action
	preparation.phaseMu.Unlock()

	switch action {
	case PersistentPreparationProvision:
		if err := createInitialPreparedEnvelope(preparation); err != nil {
			return false, err
		}
	case PersistentPreparationOpen:
		preparation.phaseMu.Lock()
		if !preparation.dekSupplied {
			preparation.phaseMu.Unlock()
			return false, fmt.Errorf("existing encrypted state requires a supplied key")
		}
		key := preparation.stagedDEK
		wipeBytes(preparation.stagedDEK[:])
		preparation.dekSupplied = false
		preparation.phaseMu.Unlock()

		path := filepath.Join(preparation.baseRoot, ownedStateSubdirectory, encryptedStateFileName)
		options := defaultEncryptedStateStoreOptions()
		options.validateRootPath = preparation.lease.validatePaths
		store, openErr := openEncryptedStateStoreWithOptions(path, key, options)
		wipeBytes(key[:])
		if openErr != nil {
			return false, openErr
		}
		preparation.phaseMu.Lock()
		if preparation.abandoned {
			preparation.phaseMu.Unlock()
			closeErr := store.Close()
			return false, errors.Join(
				fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token),
				closeErr,
			)
		}
		preparation.store = store
		preparation.phaseMu.Unlock()
	default:
		return false, fmt.Errorf("unknown persistent preparation action %q", action)
	}

	preparation.phaseMu.Lock()
	store := preparation.store
	preparation.phaseMu.Unlock()
	if store == nil {
		return false, fmt.Errorf("persistent StateStore was not prepared")
	}
	empty, err = store.logicalEmpty()
	if err != nil {
		return false, err
	}
	preparation.phaseMu.Lock()
	if preparation.abandoned {
		preparation.phaseMu.Unlock()
		return false, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	preparation.storeEmpty = empty
	preparation.phaseMu.Unlock()
	return empty, nil
}

// CompletePersistentCustody is the native half of normal Keybay completion.
// It is deliberately separate from FinishCustody, which is only for an
// abandoned operation and possible compensating deletion.
func CompletePersistentCustody(token uint64) error {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if err := preparation.requireLiveLocked(); err != nil {
		return err
	}
	if preparation.operationInFlight {
		return fmt.Errorf("%w: state preparation operation is still active", ErrLifecycleBusy)
	}
	if !preparation.custodyActive || preparation.custodyCompleted {
		return fmt.Errorf("state custody is not active for preparation token %d", token)
	}
	if !preparation.custodyResolved {
		return fmt.Errorf("state custody was not resolved for preparation token %d", token)
	}
	if preparation.custodyWriteAttempted && preparation.envelopeOutcome != envelopeWriteCommitted {
		return fmt.Errorf("fresh custody write has no committed encrypted envelope")
	}
	wipeBytes(preparation.stagedDEK[:])
	preparation.dekSupplied = false
	preparation.custodyActive = false
	preparation.custodyCompleted = true
	return nil
}

// FinishPreparedPersistentState closes a normal idle probe/no-state path and
// releases its lease. A prepared store must instead be atomically adopted by a
// runtime when startup/logout continues.
func FinishPreparedPersistentState(token uint64) error {
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		return err
	}
	preparation.phaseMu.Lock()
	if preparation.finishing || preparation.adopted {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("%w: preparation token %d is terminating", ErrRuntimeStale, token)
	}
	if !preparation.acquisitionSettled || preparation.lease == nil {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("%w: state lease acquisition has not completed", ErrLifecycleBusy)
	}
	if preparation.operationInFlight || preparation.custodyActive {
		preparation.phaseMu.Unlock()
		return fmt.Errorf("%w: persistent preparation is still active", ErrLifecycleBusy)
	}
	preparation.finishing = true
	preparation.phaseMu.Unlock()
	return finishClaimedPersistentPreparation(preparation, nil)
}

// adoptPersistentPreparation moves the exact open Store and already-held lease
// into a candidate without any unlock/relock gap.
func (c *runtimeController) adoptPersistentPreparation(token uint64, config runtimeConfig) (*nodeRuntime, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if token == 0 {
		return nil, fmt.Errorf("runtime preparation token must be non-zero")
	}
	if err := c.cleanupAdmissionErrorLocked(); err != nil {
		return nil, err
	}
	if _, abandoned := c.abandonedTokens[token]; abandoned {
		delete(c.abandonedTokens, token)
		return nil, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if c.current != nil || c.candidate != nil || c.draining != nil || c.logout != nil || c.reset != nil {
		return nil, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	preparation := c.persistentPreparation
	if preparation == nil {
		return nil, fmt.Errorf("%w: prepared persistent token %d is not current", ErrRuntimeStale, token)
	}
	if preparation.token != token {
		return nil, fmt.Errorf(
			"%w: preparation token %d is active while token %d attempted adoption",
			ErrLifecycleBusy,
			preparation.token,
			token,
		)
	}
	preparation.phaseMu.Lock()
	if err := preparation.requireLiveLocked(); err != nil {
		preparation.phaseMu.Unlock()
		return nil, err
	}
	if preparation.operationInFlight || preparation.custodyActive || !preparation.custodyCompleted {
		preparation.phaseMu.Unlock()
		return nil, fmt.Errorf("%w: persistent state custody is not complete", ErrLifecycleBusy)
	}
	if preparation.store == nil || preparation.lease == nil {
		preparation.phaseMu.Unlock()
		return nil, fmt.Errorf("persistent StateStore or lease was not prepared")
	}
	if err := preparation.lease.validatePaths(); err != nil {
		preparation.phaseMu.Unlock()
		return nil, fmt.Errorf("adopt persistent state lease boundary: %w", err)
	}

	candidate := newNodeRuntime(nodeEpoch.Load(), token, config)
	candidate.store = preparation.store
	candidate.storeCloser = preparation.store
	candidate.stateLease = preparation.lease
	preparation.store = nil
	preparation.lease = nil
	preparation.adopted = true
	wipeBytes(preparation.stagedDEK[:])
	preparation.dekSupplied = false
	c.persistentPreparation = nil
	c.candidate = candidate
	preparation.phaseMu.Unlock()
	preparation.complete(nil)
	return candidate, nil
}
