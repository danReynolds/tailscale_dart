//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func configuredPreparationRootForTest(t *testing.T) (root string) {
	t.Helper()
	stateDir := configureFreshStateRootForTest(t)
	root = filepath.Dir(stateDir)
	t.Cleanup(func() {
		runtimes.mu.Lock()
		preparation := runtimes.persistentPreparation
		if preparation != nil {
			runtimes.persistentPreparation = nil
		}
		runtimes.cleanupFailure = nil
		runtimes.mu.Unlock()
		if preparation != nil {
			preparation.phaseMu.Lock()
			preparation.abandoned = true
			preparation.phaseMu.Unlock()
			_ = preparation.cleanupResources()
			preparation.complete(nil)
		}
	})
	return root
}

func testPreparedDEK() []byte {
	key := make([]byte, encryptedStateKeySize)
	for index := range key {
		key[index] = byte(index*7 + 3)
	}
	key[0] = 0
	key[len(key)-1] = 0xff
	return key
}

func assertPreparationDEKWiped(t *testing.T, preparation *persistentPreparation) {
	t.Helper()
	preparation.phaseMu.Lock()
	defer preparation.phaseMu.Unlock()
	if preparation.dekSupplied {
		t.Fatal("preparation still reports a staged DEK")
	}
	for index, value := range preparation.stagedDEK {
		if value != 0 {
			t.Fatalf("staged DEK byte %d was not wiped", index)
		}
	}
}

func TestPersistentPreparationIsLatentAndTokenBound(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 41
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}

	lockInfo, err := os.Lstat(filepath.Join(root, stateLeaseFilename))
	if err != nil {
		t.Fatalf("lease infrastructure: %v", err)
	}
	if got := lockInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("lease mode = %04o, want 0600", got)
	}
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	if _, err := os.Lstat(stateDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("latent preparation created the StateStore subtree: %v", err)
	}

	if err := BeginPersistentPreparation(token + 1); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("second preparation error = %v, want ErrLifecycleBusy", err)
	}
	if _, err := StartRuntime("node", "", "", false); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("legacy StartRuntime error = %v, want ErrLifecycleBusy", err)
	}
	if _, err := os.Lstat(stateDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("blocked legacy startup created state: %v", err)
	}

	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	for _, length := range []int{0, encryptedStateKeySize - 1, encryptedStateKeySize + 1} {
		if err := SupplyPreparedDEK(token, make([]byte, length)); !errors.Is(err, ErrInvalidStateKey) {
			t.Fatalf("SupplyPreparedDEK length %d error = %v, want ErrInvalidStateKey", length, err)
		}
	}
	key := testPreparedDEK()
	if err := SupplyPreparedDEK(token, key); err != nil {
		t.Fatal(err)
	}
	key[1] ^= 0xff
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	preparation.phaseMu.Lock()
	if preparation.stagedDEK[1] == key[1] {
		preparation.phaseMu.Unlock()
		t.Fatal("native preparation aliased the caller's DEK buffer")
	}
	preparation.phaseMu.Unlock()
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err == nil {
		t.Fatal("preparation accepted a second DEK")
	}

	result, err := AbandonRuntime(token)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Matched || !result.Pending || !result.CustodyHeld ||
		result.CustodyDisposition != CustodyDispositionNone {
		t.Fatalf("abandon result = %+v", result)
	}
	if err := BeginPersistentPreparation(token + 1); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("custody did not retain admission: %v", err)
	}
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}
	if err := AwaitRuntimeQuiescence(token); err != nil {
		t.Fatal(err)
	}
	if err := BeginPersistentPreparation(token + 1); err != nil {
		t.Fatalf("replacement preparation: %v", err)
	}
	second, err := AbandonRuntime(token + 1)
	if err != nil {
		t.Fatal(err)
	}
	if !second.Matched || second.Pending || second.CustodyHeld {
		t.Fatalf("non-custody abandon result = %+v", second)
	}
	runtimes.mu.Lock()
	_, retainedOutcome := runtimes.completedPreparations[token+1]
	_, retainedTombstone := runtimes.abandonedTokens[token+1]
	runtimes.mu.Unlock()
	if retainedOutcome || retainedTombstone {
		t.Fatal("synchronous preparation quarantine retained bookkeeping")
	}
}

func TestPersistentPreparationCompensatesFreshWriteBeforeEnvelope(t *testing.T) {
	configuredPreparationRootForTest(t)
	const token = 51
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyWriteAttempted(token); err != nil {
		t.Fatal(err)
	}
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err != nil {
		t.Fatal(err)
	}

	result, err := AbandonRuntime(token)
	if err != nil {
		t.Fatal(err)
	}
	if !result.CustodyHeld || result.CustodyDisposition != CustodyDispositionCompensateKey {
		t.Fatalf("abandon result = %+v, want compensateKey", result)
	}
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationWaitsForRenameOutcome(t *testing.T) {
	root := configuredPreparationRootForTest(t)
	const token = 61
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyWriteAttempted(token); err != nil {
		t.Fatal(err)
	}
	keyBytes := testPreparedDEK()
	if err := SupplyPreparedDEK(token, keyBytes); err != nil {
		t.Fatal(err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	var key [encryptedStateKeySize]byte
	copy(key[:], keyBytes)
	beforeRename := make(chan struct{})
	allowRename := make(chan struct{})
	writeResult := make(chan error, 1)
	go func() {
		writeResult <- runInitialEnvelopeWrite(
			preparation,
			func(preparedKey *[encryptedStateKeySize]byte, recordCommitted func()) (*encryptedStateStore, error) {
				options := defaultEncryptedStateStoreOptions()
				options.recordInitialCommit = recordCommitted
				options.fault = func(stage encryptedStateWriteStage) error {
					if stage == encryptedStateBeforeRename {
						close(beforeRename)
						<-allowRename
					}
					return nil
				}
				return createEncryptedStateStoreWithOptions(
					filepath.Join(root, ownedStateSubdirectory, encryptedStateFileName),
					*preparedKey,
					options,
				)
			},
		)
	}()
	<-beforeRename
	assertPreparationDEKWiped(t, preparation)

	type abandonReceipt struct {
		result RuntimeCloseResult
		err    error
	}
	abandoned := make(chan abandonReceipt, 1)
	go func() {
		result, err := AbandonRuntime(token)
		abandoned <- abandonReceipt{result: result, err: err}
	}()
	select {
	case receipt := <-abandoned:
		t.Fatalf("abandon returned before rename outcome: %+v err=%v", receipt.result, receipt.err)
	case <-time.After(75 * time.Millisecond):
	}
	close(allowRename)
	if err := <-writeResult; err != nil {
		t.Fatalf("initial envelope write: %v", err)
	}
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err == nil {
		t.Fatal("preparation accepted another DEK after envelope write started")
	}
	receipt := <-abandoned
	if receipt.err != nil {
		t.Fatal(receipt.err)
	}
	if !receipt.result.CustodyHeld || receipt.result.CustodyDisposition != CustodyDispositionPreserveCoherentPair {
		t.Fatalf("abandon result = %+v, want preserveCoherentPair", receipt.result)
	}
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(root, ownedStateSubdirectory, encryptedStateFileName)
	reopened, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("reopen committed envelope: %v", err)
	}
	if err := reopened.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationPreCommitFailureCompensates(t *testing.T) {
	configuredPreparationRootForTest(t)
	const token = 71
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyWriteAttempted(token); err != nil {
		t.Fatal(err)
	}
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err != nil {
		t.Fatal(err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatal(err)
	}
	injected := errors.New("before envelope commit")
	if err := runInitialEnvelopeWrite(
		preparation,
		func(*[encryptedStateKeySize]byte, func()) (*encryptedStateStore, error) {
			return nil, injected
		},
	); !errors.Is(err, injected) {
		t.Fatalf("write error = %v, want injected", err)
	}
	assertPreparationDEKWiped(t, preparation)
	result, err := AbandonRuntime(token)
	if err != nil {
		t.Fatal(err)
	}
	if result.CustodyDisposition != CustodyDispositionCompensateKey {
		t.Fatalf("abandon result = %+v, want compensateKey", result)
	}
	if err := FinishCustody(token, true); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentPreparationFailedCompensationPoisonsAdmission(t *testing.T) {
	configuredPreparationRootForTest(t)
	const token = 81
	if err := BeginPersistentPreparation(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyActive(token); err != nil {
		t.Fatal(err)
	}
	if err := MarkCustodyWriteAttempted(token); err != nil {
		t.Fatal(err)
	}
	if err := SupplyPreparedDEK(token, testPreparedDEK()); err != nil {
		t.Fatal(err)
	}
	if _, err := AbandonRuntime(token); err != nil {
		t.Fatal(err)
	}
	if err := FinishCustody(token, false); !errors.Is(err, ErrRuntimeCleanupFailed) {
		t.Fatalf("FinishCustody error = %v, want ErrRuntimeCleanupFailed", err)
	}
	preparation, err := persistentPreparationForToken(token)
	if err != nil {
		t.Fatalf("failed compensation did not retain preparation: %v", err)
	}
	preparation.phaseMu.Lock()
	for index, value := range preparation.stagedDEK {
		if value != 0 {
			preparation.phaseMu.Unlock()
			t.Fatalf("staged DEK byte %d was retained after failed compensation", index)
		}
	}
	if preparation.dekSupplied || preparation.store != nil || preparation.lease == nil {
		preparation.phaseMu.Unlock()
		t.Fatalf("failed-compensation resources = dek:%v store:%v lease:%v", preparation.dekSupplied, preparation.store != nil, preparation.lease != nil)
	}
	preparation.phaseMu.Unlock()
	if err := BeginPersistentPreparation(token + 1); !errors.Is(err, ErrRuntimeCleanupFailed) {
		t.Fatalf("replacement preparation error = %v, want ErrRuntimeCleanupFailed", err)
	}
	if err := FinishCustody(token+1, true); !errors.Is(err, ErrRuntimeStale) {
		t.Fatalf("stale FinishCustody error = %v, want ErrRuntimeStale", err)
	}
}

func TestAbandonBeforePersistentPreparationIsTokenQualified(t *testing.T) {
	configuredPreparationRootForTest(t)
	if result, err := AbandonRuntime(91); err != nil || result.Matched {
		t.Fatalf("pre-abandon result = %+v err=%v", result, err)
	}
	if err := BeginPersistentPreparation(91); !errors.Is(err, ErrStartupAbandoned) {
		t.Fatalf("abandoned token begin error = %v, want ErrStartupAbandoned", err)
	}
	if err := BeginPersistentPreparation(92); err != nil {
		t.Fatalf("different token begin: %v", err)
	}
	if _, err := AbandonRuntime(92); err != nil {
		t.Fatal(err)
	}
}
