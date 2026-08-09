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

func TestNativeLifecycleRequiresFrozenConfiguration(t *testing.T) {
	runtimes.mu.Lock()
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousLogLevel := runtimes.logLevel
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.logLevel = 0
	runtimes.mu.Unlock()
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
		runtimes.logLevel = previousLogLevel
		runtimes.mu.Unlock()
	})

	if _, err := StartRuntime("node", "", "https://control/", false); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("StartRuntime error = %v, want ErrConfigurationMismatch", err)
	}
	if err := Logout(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("Logout error = %v, want ErrConfigurationMismatch", err)
	}
	if _, err := ClassifyConfiguredIdleState(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("ClassifyConfiguredIdleState error = %v, want ErrConfigurationMismatch", err)
	}
}

func TestConfiguredStateDirRejectsReplacedRoot(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	root := filepath.Dir(stateDir)
	if err := os.RemoveAll(root); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}

	if _, err := configuredStateDir(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("configuredStateDir error = %v, want replaced-root mismatch", err)
	}
}

func TestRuntimeController_ReservationAndConfigIdentity(t *testing.T) {
	var controller runtimeController
	config := runtimeConfig{
		hostname:   "Node-A",
		controlURL: "https://control.example/",
		ephemeral:  false,
	}

	candidate, active, err := controller.reserve(config)
	if err != nil || candidate == nil || active != nil {
		t.Fatalf("first reserve = (%v, %v, %v), want a candidate", candidate, active, err)
	}
	if _, _, err := controller.reserve(config); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("concurrent reserve error = %v, want ErrLifecycleBusy", err)
	}
	if err := controller.commit(candidate); err != nil {
		t.Fatalf("commit: %v", err)
	}

	next, active, err := controller.reserve(config)
	if err != nil || next != nil || active != candidate {
		t.Fatalf("same-config reserve = (%v, %v, %v), want current runtime", next, active, err)
	}
	mismatch := config
	mismatch.hostname = "Node-B"
	if _, _, err := controller.reserve(mismatch); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("mismatched reserve error = %v, want ErrConfigurationMismatch", err)
	}
	if controller.current != candidate {
		t.Fatal("configuration mismatch replaced the active runtime")
	}
	candidate.cancel()
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
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousLogLevel := runtimes.logLevel
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.logLevel = 0
	runtimes.mu.Unlock()
	previousNativeLogLevel := atomic.LoadInt32(&LogLevel)
	previousRawDisco, hadRawDisco := os.LookupEnv("TS_ENABLE_RAW_DISCO")
	t.Cleanup(func() {
		_, _ = closeCurrentRuntime()
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
		runtimes.logLevel = previousLogLevel
		runtimes.mu.Unlock()
		atomic.StoreInt32(&LogLevel, previousNativeLogLevel)
		if hadRawDisco {
			_ = os.Setenv("TS_ENABLE_RAW_DISCO", previousRawDisco)
		} else {
			_ = os.Unsetenv("TS_ENABLE_RAW_DISCO")
		}
	})

	root := t.TempDir()
	if _, err := Configure(root, 0); err != nil {
		t.Fatalf("Configure: %v", err)
	}
	return filepath.Join(root, ownedStateSubdirectory)
}

func withActiveRuntimeForTest(t *testing.T, config runtimeConfig) {
	t.Helper()
	runtime := newNodeRuntime(nodeEpoch.Load(), config)
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
	runtime := newNodeRuntime(nodeEpoch.Load(), runtimeConfig{})
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
	runtime := newNodeRuntime(nodeEpoch.Load(), runtimeConfig{})
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

func TestClassifyIdleState_ExactLegacyNamesOnly(t *testing.T) {
	for _, name := range []string{"state.db", "state.db-wal", "state.db-shm"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, name)
			if err := os.WriteFile(path, []byte("opaque"), 0o600); err != nil {
				t.Fatal(err)
			}
			state, err := ClassifyIdleState(dir)
			if err != nil || state != IdleStateLegacy {
				t.Fatalf("ClassifyIdleState = (%q, %v), want legacy", state, err)
			}
		})
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "state.db.backup"), []byte("opaque"), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := ClassifyIdleState(dir)
	if err != nil || state != IdleStateAbsent {
		t.Fatalf("unrecognized occupancy = (%q, %v), want absent", state, err)
	}
}

func TestConfigure_IsIdempotentForNativeAliasesAndRejectsMismatch(t *testing.T) {
	runtimes.mu.Lock()
	previousConfigured := runtimes.configured
	previousRoot := runtimes.stateRoot
	previousRootInfo := runtimes.stateRootInfo
	previousLogLevel := runtimes.logLevel
	runtimes.configured = false
	runtimes.stateRoot = ""
	runtimes.stateRootInfo = nil
	runtimes.logLevel = 0
	runtimes.mu.Unlock()
	previousNativeLogLevel := atomic.LoadInt32(&LogLevel)
	previousRawDisco, hadRawDisco := os.LookupEnv("TS_ENABLE_RAW_DISCO")
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.configured = previousConfigured
		runtimes.stateRoot = previousRoot
		runtimes.stateRootInfo = previousRootInfo
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
	root := filepath.Join(parent, "root")
	resolved, err := Configure(root, 1)
	if err != nil {
		t.Fatalf("Configure(root): %v", err)
	}
	alias := filepath.Join(parent, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatalf("symlink alias: %v", err)
	}
	viaAlias, err := Configure(alias, 1)
	if err != nil {
		t.Fatalf("Configure(alias): %v", err)
	}
	if viaAlias != resolved {
		t.Fatalf("canonical aliases differ: %q != %q", viaAlias, resolved)
	}
	if _, err := Configure(alias, 2); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("log-level mismatch error = %v", err)
	}
	other := filepath.Join(parent, "other")
	if _, err := Configure(other, 1); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("root mismatch error = %v", err)
	}
	if _, err := os.Lstat(other); !os.IsNotExist(err) {
		t.Fatalf("mismatched init created or modified its proposed root: %v", err)
	}
}
