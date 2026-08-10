//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestPersistentPreparationRejectsFilesystemWorkBeforeLeaseSettles(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 16001
	preparation := newPersistentPreparation(token, root)
	runtimes.mu.Lock()
	runtimes.persistentPreparation = preparation
	runtimes.mu.Unlock()

	if _, err := InspectPersistentPreparation(token); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("Inspect error = %v, want ErrLifecycleBusy", err)
	}
	if err := FinishPreparedPersistentState(token); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("early Finish error = %v, want ErrLifecycleBusy", err)
	}

	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	preparation.phaseMu.Lock()
	preparation.acquisitionSettled = true
	preparation.lease = lease
	preparation.phaseMu.Unlock()
	if err := FinishPreparedPersistentState(token); err != nil {
		t.Fatal(err)
	}

	reacquired, err := acquireStateLease(root)
	if err != nil {
		t.Fatalf("late-acquired lease leaked after finish: %v", err)
	}
	if err := reacquired.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationProvisionOpenAndFailClosedMatrix(t *testing.T) {
	configuredPreparationRootForTest(t)
	key := testPreparedDEK()

	const provisionToken = 16002
	if err := BeginPersistentPreparation(provisionToken); err != nil {
		t.Fatal(err)
	}
	if layout, err := InspectPersistentPreparation(provisionToken); err != nil || layout != PersistentStateLayoutAbsent {
		t.Fatalf("fresh layout = %q, %v", layout, err)
	}
	if err := MarkCustodyActive(provisionToken); err != nil {
		t.Fatal(err)
	}
	if action, err := ResolvePersistentCustody(provisionToken, false); err != nil || action != PersistentPreparationProvision {
		t.Fatalf("fresh resolution = %q, %v", action, err)
	}
	if err := MarkCustodyWriteAttempted(provisionToken); err != nil {
		t.Fatal(err)
	}
	if err := SupplyPreparedDEK(provisionToken, key); err != nil {
		t.Fatal(err)
	}
	if empty, err := PreparePersistentState(provisionToken); err != nil || !empty {
		t.Fatalf("fresh preparation empty = %v, err = %v", empty, err)
	}
	if err := CompletePersistentCustody(provisionToken); err != nil {
		t.Fatal(err)
	}
	if err := FinishPreparedPersistentState(provisionToken); err != nil {
		t.Fatal(err)
	}

	const missingToken = 16003
	if err := BeginPersistentPreparation(missingToken); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPersistentPreparation(missingToken); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(missingToken); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolvePersistentCustody(missingToken, false); !errors.Is(err, ErrMissingStateDEK) {
		t.Fatalf("missing-key error = %v, want ErrMissingStateDEK", err)
	}
	settleAbandonedPreparationForTest(t, missingToken)

	const wrongKeyToken = 16004
	if err := BeginPersistentPreparation(wrongKeyToken); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPersistentPreparation(wrongKeyToken); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(wrongKeyToken); err != nil {
		t.Fatal(err)
	}
	if action, err := ResolvePersistentCustody(wrongKeyToken, true); err != nil || action != PersistentPreparationOpen {
		t.Fatalf("existing resolution = %q, %v", action, err)
	}
	wrong := append([]byte(nil), key...)
	wrong[0] ^= 0xff
	if err := SupplyPreparedDEK(wrongKeyToken, wrong); err != nil {
		t.Fatal(err)
	}
	if _, err := PreparePersistentState(wrongKeyToken); !errors.Is(err, ErrEncryptedStateAuthentication) {
		t.Fatalf("wrong-key error = %v, want authentication failure", err)
	}
	settleAbandonedPreparationForTest(t, wrongKeyToken)

	const openToken = 16005
	if err := BeginPersistentPreparation(openToken); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPersistentPreparation(openToken); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(openToken); err != nil {
		t.Fatal(err)
	}
	if action, err := ResolvePersistentCustody(openToken, true); err != nil || action != PersistentPreparationOpen {
		t.Fatalf("open resolution = %q, %v", action, err)
	}
	if err := SupplyPreparedDEK(openToken, key); err != nil {
		t.Fatal(err)
	}
	if empty, err := PreparePersistentState(openToken); err != nil || !empty {
		t.Fatalf("opened preparation empty = %v, err = %v", empty, err)
	}
	if err := CompletePersistentCustody(openToken); err != nil {
		t.Fatal(err)
	}
	if err := FinishPreparedPersistentState(openToken); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationOrphanedKeyFailsBeforeStoreCreation(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 16006
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if layout, err := InspectPersistentPreparation(token); err != nil || layout != PersistentStateLayoutAbsent {
		t.Fatalf("layout = %q, %v", layout, err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolvePersistentCustody(token, true); !errors.Is(err, ErrOrphanedStateDEK) {
		t.Fatalf("orphan error = %v, want ErrOrphanedStateDEK", err)
	}
	settleAbandonedPreparationForTest(t, token)
	if layout, err := inspectPersistentStateLayout(root); err != nil || layout != PersistentStateLayoutAbsent {
		t.Fatalf("orphan resolution mutated layout = %q, %v", layout, err)
	}
}

func TestPersistentPreparationTerminalPhaseRejectsReplayAndStalePointer(t *testing.T) {
	configuredPreparationRootForTest(t)
	const token = 16007
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if _, err := InspectPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolvePersistentCustody(token, false); err != nil {
		t.Fatal(err)
	}
	if err := CompletePersistentCustody(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("custody replay error = %v, want ErrLifecycleBusy", err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	if err := FinishPreparedPersistentState(token); err != nil {
		t.Fatal(err)
	}
	if _, err := preparation.beginOperation("stale replay"); !errors.Is(err, ErrRuntimeStale) {
		t.Fatalf("stale pointer error = %v, want ErrRuntimeStale", err)
	}
}

func TestAdoptPersistentPreparationClassifiesBusyAndMissingTokens(t *testing.T) {
	const activeToken = 16009
	var controller runtimeController
	controller.persistentPreparation = newPersistentPreparation(activeToken, t.TempDir())

	if _, err := controller.adoptPersistentPreparation(activeToken+1, runtimeConfig{}); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("different-token adoption error = %v, want ErrLifecycleBusy", err)
	}
	controller.persistentPreparation = nil
	if _, err := controller.adoptPersistentPreparation(activeToken+1, runtimeConfig{}); !errors.Is(err, ErrRuntimeStale) {
		t.Fatalf("missing-token adoption error = %v, want ErrRuntimeStale", err)
	}
}

func TestActiveRuntimeProbePassesExactPersistentPreparationToAdoption(t *testing.T) {
	const activeToken = 16010
	var controller runtimeController
	controller.persistentPreparation = newPersistentPreparation(activeToken, t.TempDir())

	refreshed, err := controller.refreshActiveRuntime(
		activeToken,
		runtimeConfig{},
		func() error {
			t.Fatal("host network refresh ran without an active runtime")
			return nil
		},
	)
	if err != nil || refreshed != nil {
		t.Fatalf("exact-token probe = (%p, %v), want (nil, nil) for adoption", refreshed, err)
	}
	if _, err := controller.refreshActiveRuntime(activeToken+1, runtimeConfig{}, nil); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("different-token probe error = %v, want ErrLifecycleBusy", err)
	}
}

func TestAdoptPersistentPreparationRacesStalePointerTerminalClaim(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	for iteration := range 32 {
		token := uint64(16100 + iteration)
		lease, err := acquireStateLease(root)
		if err != nil {
			t.Fatalf("iteration %d acquire lease: %v", iteration, err)
		}
		store := &encryptedStateStore{options: defaultEncryptedStateStoreOptions()}
		preparation := newPersistentPreparation(token, root)
		preparation.acquisitionSettled = true
		preparation.custodyCompleted = true
		preparation.lease = lease
		preparation.store = store
		runtimes.mu.Lock()
		if runtimes.persistentPreparation != nil || runtimes.candidate != nil {
			runtimes.mu.Unlock()
			t.Fatalf("iteration %d found non-idle controller", iteration)
		}
		runtimes.persistentPreparation = preparation
		runtimes.mu.Unlock()

		start := make(chan struct{})
		var wait sync.WaitGroup
		wait.Add(2)
		var candidate *nodeRuntime
		var adoptErr, finishErr error
		go func() {
			defer wait.Done()
			<-start
			candidate, adoptErr = runtimes.adoptPersistentPreparation(token, runtimeConfig{})
		}()
		go func() {
			defer wait.Done()
			<-start
			finishErr = finishPersistentPreparation(preparation, nil)
		}()
		close(start)
		wait.Wait()

		select {
		case <-preparation.done:
		default:
			t.Fatalf("iteration %d did not publish a terminal preparation result", iteration)
		}
		if adoptErr == nil {
			if candidate == nil || !errors.Is(finishErr, ErrRuntimeStale) {
				t.Fatalf("iteration %d adoption won: candidate=%p finishErr=%v", iteration, candidate, finishErr)
			}
			assertStateLeaseBusy(t, root)
			cleanupErr := candidate.closeUnstarted()
			if err := runtimes.release(candidate, cleanupErr); err != nil {
				t.Fatalf("iteration %d release adopted candidate: %v", iteration, err)
			}
		} else {
			if finishErr != nil || !errors.Is(adoptErr, ErrRuntimeStale) || candidate != nil {
				t.Fatalf("iteration %d terminal cleanup won: candidate=%p adoptErr=%v finishErr=%v", iteration, candidate, adoptErr, finishErr)
			}
		}

		reacquired, err := acquireStateLease(root)
		if err != nil {
			t.Fatalf("iteration %d terminal path leaked lease: %v", iteration, err)
		}
		if err := reacquired.Release(); err != nil {
			t.Fatalf("iteration %d release verification lease: %v", iteration, err)
		}
	}
}

func TestAdoptedPersistentStoreRejectsReplacementRootWrites(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 16133
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if layout, err := InspectPersistentPreparation(token); err != nil || layout != PersistentStateLayoutAbsent {
		t.Fatalf("layout = %q, %v", layout, err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if action, err := ResolvePersistentCustody(token, false); err != nil || action != PersistentPreparationProvision {
		t.Fatalf("custody resolution = %q, %v", action, err)
	}
	if err := MarkCustodyWriteAttempted(token); err != nil {
		t.Fatal(err)
	}
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err != nil {
		t.Fatal(err)
	}
	if _, err := PreparePersistentState(token); err != nil {
		t.Fatal(err)
	}
	if err := CompletePersistentCustody(token); err != nil {
		t.Fatal(err)
	}
	candidate, err := runtimes.adoptPersistentPreparation(token, runtimeConfig{hostname: "replacement-test"})
	if err != nil {
		t.Fatal(err)
	}
	if err := candidate.store.WriteState("runtime-write", []byte("same")); err != nil {
		t.Fatal(err)
	}

	moved := root + "-runtime-original"
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(moved) })
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	clearStateLeaseAdmissionAfterTest(t, moved)

	// The cached value is unchanged, but the write must still validate the
	// retained root instead of returning through its no-op fast path.
	err = candidate.store.WriteState("runtime-write", []byte("same"))
	if !errors.Is(err, ErrConfigurationMismatch) || !errors.Is(err, ErrEncryptedStatePathSecurity) {
		t.Fatalf("replacement-root WriteState error = %v, want path security and configuration mismatch", err)
	}
	if _, err := os.Lstat(filepath.Join(root, ownedStateSubdirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replacement root was mutated: %v", err)
	}
	cleanupErr := candidate.closeUnstarted()
	if err := runtimes.release(candidate, cleanupErr); !errors.Is(err, ErrRuntimeCleanupFailed) || !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("replacement-root candidate cleanup error = %v", err)
	}
}

func TestAdoptPersistentPreparationRejectsReplacementRoot(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 16134
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	preparation := newPersistentPreparation(token, root)
	preparation.acquisitionSettled = true
	preparation.custodyCompleted = true
	preparation.lease = lease
	preparation.store = &encryptedStateStore{
		options: defaultEncryptedStateStoreOptions(),
	}
	runtimes.mu.Lock()
	runtimes.persistentPreparation = preparation
	runtimes.mu.Unlock()

	moved := root + "-pre-adoption-original"
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := runtimes.adoptPersistentPreparation(token, runtimeConfig{}); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("replacement-root adoption error = %v, want ErrConfigurationMismatch", err)
	}

	// Restore the admitted inode so cleanup can prove release rather than
	// intentionally poisoning process admission for the remainder of the test.
	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(moved, root); err != nil {
		t.Fatal(err)
	}
	if err := FinishPreparedPersistentState(token); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationRejectsRootReplacementAtOperationBoundaries(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 16132
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	finish, err := preparation.beginOperation("replacement test")
	if err != nil {
		t.Fatal(err)
	}

	moved := root + "-original"
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(moved) })
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	clearStateLeaseAdmissionAfterTest(t, moved)

	if err := finish(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("completion boundary error = %v, want ErrConfigurationMismatch", err)
	}
	if _, err := os.Lstat(filepath.Join(root, ownedStateSubdirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replacement root was mutated: %v", err)
	}
	result, err := AbandonRuntime(token)
	if !result.Matched || !errors.Is(err, ErrRuntimeCleanupFailed) || !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("replacement terminal result = %+v err=%v", result, err)
	}
}

func TestFinishCustodyRejectsEarlyTeardown(t *testing.T) {
	configuredPreparationRootForTest(t)
	const token = 16008
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	operationDone := make(chan struct{})
	preparation.phaseMu.Lock()
	preparation.abandoned = true
	preparation.operationInFlight = true
	preparation.operationDone = operationDone
	preparation.phaseMu.Unlock()

	if err := FinishCustody(token, true); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("early FinishCustody error = %v, want ErrLifecycleBusy", err)
	}
	preparation.phaseMu.Lock()
	preparation.operationInFlight = false
	preparation.operationDone = nil
	close(operationDone)
	preparation.phaseMu.Unlock()
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}
}

func settleAbandonedPreparationForTest(t *testing.T, token uint64) {
	t.Helper()
	result, err := AbandonRuntime(token)
	if err != nil {
		t.Fatal(err)
	}
	if !result.CustodyHeld {
		t.Fatalf("abandon result = %+v, want retained custody", result)
	}
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}
}
