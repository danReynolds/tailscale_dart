package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"tailscale.com/tsnet"
)

const testKeybayNamespace = "dev.tailscale.dart.test.tailscale"

func TestNativeLifecycleRequiresFrozenConfiguration(t *testing.T) {
	runtimes.mu.Lock()
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil || runtimes.logout != nil || runtimes.reset != nil || runtimes.persistentPreparation != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousKeybayNamespace := runtimes.keybayNamespace
	previousLogLevel := runtimes.logLevel
	previousAbandonedTokens := runtimes.abandonedTokens
	previousStartCalls := runtimes.startCalls
	previousCompletedPreparations := runtimes.completedPreparations
	previousCompletedLifecycle := runtimes.completedLifecycle
	previousCleanupFailure := runtimes.cleanupFailure
	previousPersistentPreparation := runtimes.persistentPreparation
	previousReset := runtimes.reset
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.keybayNamespace = ""
	runtimes.logLevel = 0
	runtimes.abandonedTokens = nil
	runtimes.startCalls = nil
	runtimes.completedPreparations = nil
	runtimes.completedLifecycle = nil
	runtimes.cleanupFailure = nil
	runtimes.persistentPreparation = nil
	runtimes.reset = nil
	runtimes.mu.Unlock()
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
		runtimes.keybayNamespace = previousKeybayNamespace
		runtimes.logLevel = previousLogLevel
		runtimes.abandonedTokens = previousAbandonedTokens
		runtimes.startCalls = previousStartCalls
		runtimes.completedPreparations = previousCompletedPreparations
		runtimes.completedLifecycle = previousCompletedLifecycle
		runtimes.cleanupFailure = previousCleanupFailure
		runtimes.persistentPreparation = previousPersistentPreparation
		runtimes.reset = previousReset
		runtimes.mu.Unlock()
	})

	if _, err := StartRuntime("node", "", "https://control/", false); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("StartRuntime error = %v, want ErrConfigurationMismatch", err)
	}
	if err := Logout(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("Logout error = %v, want ErrConfigurationMismatch", err)
	}
}

func TestConfiguredStateDirRejectsReplacedRoot(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	root := filepath.Dir(stateDir)
	// Keep the original inode allocated while recreating the configured lexical
	// path. A remove-then-mkdir test can immediately reuse the same inode on
	// Linux filesystems, making os.SameFile correctly report identity and the
	// test nondeterministic.
	originalRoot := root + "-original"
	if err := os.Rename(root, originalRoot); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(originalRoot) })
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	originalInfo, err := os.Stat(originalRoot)
	if err != nil {
		t.Fatal(err)
	}
	replacementInfo, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	if os.SameFile(originalInfo, replacementInfo) {
		t.Fatal("test setup reused the configured root identity")
	}

	if _, err := configuredStateDir(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("configuredStateDir error = %v, want replaced-root mismatch", err)
	}
}

func TestLogoutRejectsSymlinkedOwnedStateWithoutRemovingTarget(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	target := t.TempDir()
	marker := filepath.Join(target, "state.db")
	if err := os.WriteFile(marker, []byte("external credentials"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, stateDir); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	if err := Logout(); err == nil {
		t.Fatal("Logout reported success for a symlinked package-owned state directory")
	}
	info, err := os.Lstat(stateDir)
	if err != nil {
		t.Fatalf("state symlink was removed: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("package-owned state path is no longer the original symlink")
	}
	got, err := os.ReadFile(marker)
	if err != nil || string(got) != "external credentials" {
		t.Fatalf("external credential target = %q, %v; want untouched", got, err)
	}
}

func TestRuntimeController_ReservationAndConfigIdentity(t *testing.T) {
	var controller runtimeController
	config := runtimeConfig{
		hostname:   "Node-A",
		controlURL: "https://control.example/",
		ephemeral:  false,
	}

	candidate, active, err := controller.reserve(1, config)
	if err != nil || candidate == nil || active != nil {
		t.Fatalf("first reserve = (%v, %v, %v), want a candidate", candidate, active, err)
	}
	if _, _, err := controller.reserve(2, config); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("concurrent reserve error = %v, want ErrLifecycleBusy", err)
	}
	if err := controller.commit(candidate); err != nil {
		t.Fatalf("commit: %v", err)
	}
	next, active, err := controller.reserve(3, config)
	if err != nil || next != nil || active != candidate {
		t.Fatalf("same-config reserve = (%v, %v, %v), want current runtime", next, active, err)
	}
	mismatch := config
	mismatch.hostname = "Node-B"
	if _, _, err := controller.reserve(4, mismatch); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("mismatched reserve error = %v, want ErrConfigurationMismatch", err)
	}
	if controller.current != candidate {
		t.Fatal("configuration mismatch replaced the active runtime")
	}
	candidate.cancel()
}

func TestRuntimeController_AbandonedTokenCannotRefreshActiveRuntime(t *testing.T) {
	config := runtimeConfig{hostname: "active", controlURL: "https://control.example/"}
	active := newNodeRuntime(nodeEpoch.Load(), 301, config)
	defer active.cancel()
	const abandonedToken = 302
	controller := runtimeController{
		current:         active,
		abandonedTokens: map[uint64]struct{}{abandonedToken: {}},
	}
	refreshCalled := false
	refreshed, err := controller.refreshActiveRuntime(abandonedToken, config, func() error {
		refreshCalled = true
		return nil
	})
	if !errors.Is(err, ErrStartupAbandoned) {
		t.Fatalf("active refresh error = %v, want ErrStartupAbandoned", err)
	}
	if refreshed != nil || refreshCalled {
		t.Fatalf("abandoned refresh = runtime:%p callback:%v, want neither", refreshed, refreshCalled)
	}
	if controller.current != active {
		t.Fatal("abandoned active refresh detached the current runtime")
	}
}

func TestRuntimeController_RefreshRejectsRuntimeDetachedDuringCallback(t *testing.T) {
	config := runtimeConfig{hostname: "active", controlURL: "https://control.example/"}
	active := newNodeRuntime(nodeEpoch.Load(), 303, config)
	defer active.cancel()
	controller := runtimeController{current: active}

	entered := make(chan struct{})
	release := make(chan struct{})
	type result struct {
		runtime *nodeRuntime
		err     error
	}
	done := make(chan result, 1)
	go func() {
		refreshed, err := controller.refreshActiveRuntime(304, config, func() error {
			close(entered)
			<-release
			return nil
		})
		done <- result{runtime: refreshed, err: err}
	}()

	<-entered
	controller.mu.Lock()
	controller.current = nil
	controller.mu.Unlock()
	close(release)

	got := <-done
	if got.runtime != nil || !errors.Is(got.err, ErrRuntimeStale) {
		t.Fatalf("refresh after detach = (%p, %v), want (nil, ErrRuntimeStale)", got.runtime, got.err)
	}
}

func TestRuntimeController_CleanupFailurePoisonsReplacementAdmission(t *testing.T) {
	var controller runtimeController
	candidate, active, err := controller.reserve(70001, runtimeConfig{})
	if err != nil || candidate == nil || active != nil {
		t.Fatalf("reserve = (%v, %v, %v), want candidate", candidate, active, err)
	}
	closeFailure := errors.New("injected store close failure")
	cleanupErr := controller.release(candidate, closeFailure)
	if !errors.Is(cleanupErr, ErrRuntimeCleanupFailed) || !errors.Is(cleanupErr, closeFailure) {
		t.Fatalf("release error = %v, want typed cleanup failure", cleanupErr)
	}
	if _, _, err := controller.reserve(70002, runtimeConfig{}); !errors.Is(err, ErrRuntimeCleanupFailed) {
		t.Fatalf("replacement reserve error = %v, want ErrRuntimeCleanupFailed", err)
	}
}

func TestCloseRuntime_TerminalReceiptSurvivesUntilRescueConsumesIt(t *testing.T) {
	configureFreshStateRootForTest(t)
	const token uint64 = 70004
	runtime := newNodeRuntime(nodeEpoch.Load(), token, runtimeConfig{})
	runtime.storeCloser = new(recordingStateStore)
	runtime.finishPreparation()
	runtimes.mu.Lock()
	runtimes.current = runtime
	runtimes.mu.Unlock()

	closed, err := CloseRuntime(token)
	if err != nil || !closed.Matched || !closed.Started || !closed.EmitStopped {
		t.Fatalf("CloseRuntime = (%+v, %v), want clean close", closed, err)
	}
	recovered, err := AbandonRuntime(token)
	if err != nil || recovered.Operation != lifecycleOperationDown || !recovered.Matched || !recovered.Started || !recovered.EmitStopped {
		t.Fatalf("receipt recovery = (%+v, %v), want exact down receipt", recovered, err)
	}
	again, err := AbandonRuntime(token)
	if err != nil || again.Matched {
		t.Fatalf("second receipt recovery = (%+v, %v), want consumed receipt", again, err)
	}
}

func TestCloseRuntime_CleanupFailureReceiptCannotBeSwallowed(t *testing.T) {
	configureFreshStateRootForTest(t)
	const token uint64 = 70005
	closeFailure := errors.New("injected server close failure")
	runtime := newNodeRuntime(nodeEpoch.Load(), token, runtimeConfig{})
	runtime.server = &tsnet.Server{}
	runtime.closeServer = func(*tsnet.Server) error { return closeFailure }
	runtime.finishPreparation()
	runtimes.mu.Lock()
	runtimes.current = runtime
	runtimes.mu.Unlock()

	closed, err := CloseRuntime(token)
	if !errors.Is(err, ErrRuntimeCleanupFailed) || !closed.CleanupFailed {
		t.Fatalf("CloseRuntime = (%+v, %v), want typed cleanup failure", closed, err)
	}
	recovered, err := AbandonRuntime(token)
	if !errors.Is(err, ErrRuntimeCleanupFailed) ||
		!errors.Is(err, closeFailure) ||
		recovered.Operation != lifecycleOperationDown ||
		!recovered.CleanupFailed {
		t.Fatalf("receipt recovery = (%+v, %v), want exact cleanup failure", recovered, err)
	}
}

func TestAbandonRuntime_RetiresTokenBeforeNativeReservation(t *testing.T) {
	configureFreshStateRootForTest(t)
	const abandonedToken uint64 = 72001

	result, err := AbandonRuntime(abandonedToken)
	if err != nil {
		t.Fatalf("AbandonRuntime: %v", err)
	}
	if result.Matched || result.Started || result.Pending {
		t.Fatalf("pre-reservation abandon result = %+v, want no allocated runtime", result)
	}
	if _, _, reserveErr := runtimes.reserve(abandonedToken, runtimeConfig{}); !errors.Is(reserveErr, ErrStartupAbandoned) {
		t.Fatalf("retired-token reserve error = %v, want ErrStartupAbandoned", reserveErr)
	}
	runtimes.mu.Lock()
	_, retained := runtimes.abandonedTokens[abandonedToken]
	runtimes.mu.Unlock()
	if retained {
		t.Fatal("consumed pre-reservation tombstone remained retained")
	}

	candidate, active, reserveErr := runtimes.reserve(72002, runtimeConfig{})
	if reserveErr != nil || candidate == nil || active != nil {
		t.Fatalf("fresh-token reserve = (%v, %v, %v), want candidate", candidate, active, reserveErr)
	}
	runtimes.release(candidate, nil)
}

func TestAbandonRuntime_ExplicitDispatchRetirementStaysBounded(t *testing.T) {
	configureFreshStateRootForTest(t)
	const firstToken uint64 = 72100
	for offset := uint64(0); offset < 1024; offset++ {
		token := firstToken + offset
		result, err := AbandonRuntime(token)
		if err != nil || result.Matched || result.Pending {
			t.Fatalf("pre-dispatch abandon %d = (%+v, %v)", token, result, err)
		}
		RetireAbandonedRuntimeToken(token)
	}
	runtimes.mu.Lock()
	retained := len(runtimes.abandonedTokens)
	runtimes.mu.Unlock()
	if retained != 0 {
		t.Fatalf("retained abandoned tokens = %d after explicit retirement, want 0", retained)
	}
}

func TestAbandonRuntime_EntryCallOwnsRetirementUntilQuiescent(t *testing.T) {
	configureFreshStateRootForTest(t)
	const token uint64 = 73100
	call, err := runtimes.beginStartCall(token)
	if err != nil {
		t.Fatal(err)
	}

	result, err := AbandonRuntime(token)
	if err != nil || result.Matched || !result.Pending {
		t.Fatalf("in-entry abandon = (%+v, %v), want unmatched pending", result, err)
	}
	RetireAbandonedRuntimeToken(token)
	runtimes.mu.Lock()
	_, retainedWhileActive := runtimes.abandonedTokens[token]
	runtimes.mu.Unlock()
	if !retainedWhileActive {
		t.Fatal("dispatch retirement removed an active entry-call tombstone")
	}

	awaited := make(chan error, 1)
	go func() { awaited <- AwaitRuntimeQuiescence(token) }()
	select {
	case err := <-awaited:
		t.Fatalf("quiescence returned before entry call: %v", err)
	default:
	}
	runtimes.finishStartCall(token, call)
	if err := <-awaited; err != nil {
		t.Fatalf("AwaitRuntimeQuiescence: %v", err)
	}
	runtimes.mu.Lock()
	_, retainedAfterExit := runtimes.abandonedTokens[token]
	_, activeAfterExit := runtimes.startCalls[token]
	runtimes.mu.Unlock()
	if retainedAfterExit || activeAfterExit {
		t.Fatal("entry-call completion retained quarantine bookkeeping")
	}
}

func TestAbandonRuntime_StaleTokenCannotCloseNewerRuntime(t *testing.T) {
	configureFreshStateRootForTest(t)
	store := new(recordingStateStore)
	runtime := newNodeRuntime(nodeEpoch.Load(), 72004, runtimeConfig{})
	runtime.storeCloser = store
	runtime.finishPreparation()
	runtimes.mu.Lock()
	runtimes.current = runtime
	runtimes.mu.Unlock()

	result, err := AbandonRuntime(72003)
	if err != nil {
		t.Fatalf("stale AbandonRuntime: %v", err)
	}
	if result.Matched || result.Started || result.Pending {
		t.Fatalf("stale abandon result = %+v, want unmatched", result)
	}
	if currentRuntime() != runtime {
		t.Fatal("stale abandon detached the newer runtime")
	}
	if got := store.closeCalls.Load(); got != 0 {
		t.Fatalf("stale abandon closed newer store %d times", got)
	}

	result, err = AbandonRuntime(runtime.token)
	if err != nil {
		t.Fatalf("matching AbandonRuntime: %v", err)
	}
	if !result.Matched || !result.Started || result.Pending {
		t.Fatalf("matching abandon result = %+v, want closed active runtime", result)
	}
	if currentRuntime() != nil {
		t.Fatal("matching abandon left runtime current")
	}
	if got := store.closeCalls.Load(); got != 1 {
		t.Fatalf("matching abandon store close calls = %d, want 1", got)
	}
}

func TestStartRuntime_AuthKeyCannotReplaceActiveIdentity(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	config := runtimeConfig{
		hostname:   "same-node",
		controlURL: "https://control.example/",
	}
	withActiveRuntimeForTest(t, config)
	before := currentRuntime()
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(stateDir, "keep")
	if err := os.WriteFile(marker, []byte("identity"), 0o600); err != nil {
		t.Fatal(err)
	}

	alreadyActive, err := StartRuntime(
		config.hostname,
		"a-different-auth-key",
		config.controlURL,
		config.ephemeral,
	)
	if err != nil {
		t.Fatalf("same-config StartRuntime: %v", err)
	}
	if !alreadyActive {
		t.Fatal("same-config StartRuntime did not report the active runtime")
	}
	if currentRuntime() != before {
		t.Fatal("auth key replaced the active runtime")
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != "identity" {
		t.Fatalf("auth key mutated persisted state: contents=%q err=%v", got, err)
	}
}

func TestStartRuntime_ConfigMismatchDoesNotTearDown(t *testing.T) {
	configureFreshStateRootForTest(t)
	config := runtimeConfig{
		hostname:   "same-node",
		controlURL: "https://control.example/",
	}
	withActiveRuntimeForTest(t, config)
	before := currentRuntime()

	_, err := StartRuntime(
		"different-node",
		"auth-key",
		config.controlURL,
		config.ephemeral,
	)
	if !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("StartRuntime error = %v, want ErrConfigurationMismatch", err)
	}
	if currentRuntime() != before {
		t.Fatal("configuration mismatch detached the active runtime")
	}
}

func configureFreshStateRootForTest(t *testing.T) string {
	t.Helper()
	runtimes.mu.Lock()
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil || runtimes.logout != nil || runtimes.reset != nil || runtimes.persistentPreparation != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousKeybayNamespace := runtimes.keybayNamespace
	previousLogLevel := runtimes.logLevel
	previousAbandonedTokens := runtimes.abandonedTokens
	previousStartCalls := runtimes.startCalls
	previousCompletedPreparations := runtimes.completedPreparations
	previousCompletedLifecycle := runtimes.completedLifecycle
	previousCleanupFailure := runtimes.cleanupFailure
	previousPersistentPreparation := runtimes.persistentPreparation
	previousReset := runtimes.reset
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.keybayNamespace = ""
	runtimes.logLevel = 0
	runtimes.abandonedTokens = nil
	runtimes.startCalls = nil
	runtimes.completedPreparations = nil
	runtimes.completedLifecycle = nil
	runtimes.cleanupFailure = nil
	runtimes.persistentPreparation = nil
	runtimes.reset = nil
	runtimes.mu.Unlock()
	previousNativeLogLevel := atomic.LoadInt32(&LogLevel)
	previousRawDisco, hadRawDisco := os.LookupEnv("TS_ENABLE_RAW_DISCO")
	// Register the TempDir cleanup before the runtime-controller cleanup below.
	// testing runs cleanups in LIFO order, so any live state lease is released
	// while its configured root still exists instead of poisoning admission.
	root := t.TempDir()
	t.Cleanup(func() {
		_, _ = closeCurrentRuntime()
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
		runtimes.keybayNamespace = previousKeybayNamespace
		runtimes.logLevel = previousLogLevel
		runtimes.abandonedTokens = previousAbandonedTokens
		runtimes.startCalls = previousStartCalls
		runtimes.completedPreparations = previousCompletedPreparations
		runtimes.completedLifecycle = previousCompletedLifecycle
		runtimes.cleanupFailure = previousCleanupFailure
		runtimes.persistentPreparation = previousPersistentPreparation
		runtimes.reset = previousReset
		runtimes.mu.Unlock()
		atomic.StoreInt32(&LogLevel, previousNativeLogLevel)
		if hadRawDisco {
			_ = os.Setenv("TS_ENABLE_RAW_DISCO", previousRawDisco)
		} else {
			_ = os.Unsetenv("TS_ENABLE_RAW_DISCO")
		}
	})

	if _, err := Configure(root, testKeybayNamespace, 0); err != nil {
		t.Fatalf("Configure: %v", err)
	}
	return filepath.Join(root, ownedStateSubdirectory)
}

func withActiveRuntimeForTest(t *testing.T, config runtimeConfig) {
	t.Helper()
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), config)
	runtimes.mu.Lock()
	previous := runtimes.current
	if runtimes.candidate != nil || runtimes.draining != nil {
		runtimes.mu.Unlock()
		t.Fatal("test cannot publish a runtime during a lifecycle transition")
	}
	runtimes.current = runtime
	runtimes.mu.Unlock()
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.current = previous
		runtimes.mu.Unlock()
		runtime.cancel()
		runtime.finishPreparation()
	})
}

type countingCloser struct{ calls atomic.Int32 }

func (c *countingCloser) Close() error {
	c.calls.Add(1)
	return nil
}

func TestNodeRuntime_CloseIsIdempotentAndCancelsContext(t *testing.T) {
	closer := new(countingCloser)
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	runtime.storeCloser = closer

	if err := runtime.close(); err != nil {
		t.Fatalf("first close: %v", err)
	}
	if err := runtime.close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
	if got := closer.calls.Load(); got != 1 {
		t.Fatalf("store Close calls = %d, want 1", got)
	}
	if runtime.ctx.Err() == nil {
		t.Fatal("runtime context remains live after close")
	}
}

func TestNodeRuntime_ConcurrentCloseInvokesOwnedClosersOnce(t *testing.T) {
	closer := new(countingCloser)
	var serverCloseCalls atomic.Int32
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	runtime.server = &tsnet.Server{}
	runtime.storeCloser = closer
	runtime.closeServer = func(*tsnet.Server) error {
		serverCloseCalls.Add(1)
		return nil
	}

	var callers sync.WaitGroup
	callers.Add(16)
	for range 16 {
		go func() {
			defer callers.Done()
			if err := runtime.close(); err != nil {
				t.Errorf("close: %v", err)
			}
		}()
	}
	callers.Wait()

	if got := serverCloseCalls.Load(); got != 1 {
		t.Fatalf("Server.Close calls = %d, want 1", got)
	}
	if got := closer.calls.Load(); got != 1 {
		t.Fatalf("Store.Close calls = %d, want 1", got)
	}
}

func TestConfigure_IsIdempotentForNativeAliasesAndRejectsMismatch(t *testing.T) {
	runtimes.mu.Lock()
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousKeybayNamespace := runtimes.keybayNamespace
	previousLogLevel := runtimes.logLevel
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.keybayNamespace = ""
	runtimes.logLevel = 0
	runtimes.mu.Unlock()
	previousNativeLogLevel := atomic.LoadInt32(&LogLevel)
	previousRawDisco, hadRawDisco := os.LookupEnv("TS_ENABLE_RAW_DISCO")
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
		runtimes.keybayNamespace = previousKeybayNamespace
		runtimes.logLevel = previousLogLevel
		runtimes.mu.Unlock()
		atomic.StoreInt32(&LogLevel, previousNativeLogLevel)
		if hadRawDisco {
			_ = os.Setenv("TS_ENABLE_RAW_DISCO", previousRawDisco)
		} else {
			_ = os.Unsetenv("TS_ENABLE_RAW_DISCO")
		}
	})

	parent := t.TempDir()
	invalidRoot := filepath.Join(parent, "invalid")
	if _, err := Configure(invalidRoot, "", 1); err == nil {
		t.Fatal("Configure accepted an empty Keybay namespace")
	}
	if _, err := Configure(invalidRoot, "   ", 1); err == nil {
		t.Fatal("Configure accepted a whitespace-only Keybay namespace")
	}
	if _, err := os.Lstat(invalidRoot); !os.IsNotExist(err) {
		t.Fatalf("invalid namespace created its proposed root: %v", err)
	}
	root := filepath.Join(parent, "root")
	resolved, err := Configure(root, testKeybayNamespace, 1)
	if err != nil {
		t.Fatalf("Configure(root): %v", err)
	}
	alias := filepath.Join(parent, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatalf("symlink alias: %v", err)
	}
	viaAlias, err := Configure(alias, testKeybayNamespace, 1)
	if err != nil {
		t.Fatalf("Configure(alias): %v", err)
	}
	if viaAlias != resolved {
		t.Fatalf("canonical aliases differ: %q != %q", viaAlias, resolved)
	}
	if _, err := Configure(alias, testKeybayNamespace, 2); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("log-level mismatch error = %v", err)
	}
	if _, err := Configure(alias, "dev.tailscale.dart.other.tailscale", 1); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("Keybay namespace mismatch error = %v", err)
	}
	other := filepath.Join(parent, "other")
	if _, err := Configure(other, testKeybayNamespace, 1); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("root mismatch error = %v", err)
	}
	if _, err := os.Lstat(other); !os.IsNotExist(err) {
		t.Fatalf("mismatched init created or modified its proposed root: %v", err)
	}
	if afterMismatch, err := Configure(root, testKeybayNamespace, 1); err != nil || afterMismatch != resolved {
		t.Fatalf("original configuration after mismatches = %q, %v; want %q, nil", afterMismatch, err, resolved)
	}
}
