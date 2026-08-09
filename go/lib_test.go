package tailscale

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"sync/atomic"
	"testing"

	"tailscale.com/tsnet"
)

// --- Logout tests ---

func publishLogoutRuntimeForTest(t *testing.T, token uint64, closer *recordingStateStore) *nodeRuntime {
	t.Helper()
	runtime := newNodeRuntime(nodeEpoch.Load(), token, runtimeConfig{})
	runtime.storeCloser = closer
	runtime.finishPreparation()
	runtimes.mu.Lock()
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil || runtimes.logout != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	runtimes.current = runtime
	runtimes.mu.Unlock()
	return runtime
}

func logoutDependenciesForTest(
	t *testing.T,
	stateDir string,
	revoke func(*nodeRuntime) error,
) runtimeLogoutDependencies {
	t.Helper()
	return runtimeLogoutDependencies{
		configuredStateDir: func() (string, error) { return stateDir, nil },
		classifyIdleState:  ClassifyIdleState,
		loadRuntimeConfig: func() (runtimeConfig, error) {
			return runtimeConfig{
				hostname:   "saved-node",
				controlURL: "https://control.example/",
				ephemeral:  true,
			}, nil
		},
		startRuntime: func(uint64, runtimeConfig, string) (uint64, error) {
			t.Fatal("unexpected temporary logout runtime")
			return 0, nil
		},
		revokeNodeKey: revoke,
		closeRuntime:  closeRuntimeForLogout,
		removeAll:     os.RemoveAll,
	}
}

func TestLogout_AbsentStateIsRemoteFreeNoOp(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	remoteCalls := 0
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		remoteCalls++
		return nil
	})

	result, err := logoutWithDependencies(101, "{}", deps)
	if err != nil {
		t.Fatalf("logoutWithDependencies: %v", err)
	}
	if !result.NoState || result.Started {
		t.Fatalf("logout result = %+v, want noState without a runtime", result)
	}
	if remoteCalls != 0 {
		t.Fatalf("remote logout calls = %d, want 0", remoteCalls)
	}
}

func TestLogoutWithToken_PreBeginCleanupFailureMarksAndRetainsReceipt(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	cleanupFailure := errors.New("injected temporary-runtime cleanup failure")
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		t.Fatal("unexpected remote logout after temporary-runtime failure")
		return nil
	})
	deps.classifyIdleState = func(string) (IdleStateClass, error) {
		return IdleStateLegacy, nil
	}
	deps.startRuntime = func(uint64, runtimeConfig, string) (uint64, error) {
		return 0, errors.Join(ErrRuntimeCleanupFailed, cleanupFailure)
	}
	previous := productionRuntimeLogoutDependencies
	productionRuntimeLogoutDependencies = deps
	t.Cleanup(func() { productionRuntimeLogoutDependencies = previous })

	const token uint64 = 1001
	result, err := LogoutWithToken(token, "network-snapshot")
	if !errors.Is(err, ErrRuntimeCleanupFailed) || !errors.Is(err, cleanupFailure) {
		t.Fatalf("LogoutWithToken error = %v, want typed cleanup failure", err)
	}
	if result.Token != token || !result.CleanupFailed {
		t.Fatalf("LogoutWithToken result = %+v, want cleanup-failed token", result)
	}

	recovered, recoveryErr := AbandonRuntime(token)
	if !errors.Is(recoveryErr, ErrRuntimeCleanupFailed) || !errors.Is(recoveryErr, cleanupFailure) {
		t.Fatalf("receipt recovery error = %v, want exact cleanup failure", recoveryErr)
	}
	if !recovered.Matched || recovered.Operation != lifecycleOperationLogout || !recovered.CleanupFailed {
		t.Fatalf("receipt recovery = %+v, want matched cleanup-failed logout", recovered)
	}
}

func TestLogout_RemoteFailureClosesRuntimeAndRetainsState(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(stateDir, "state.db")
	if err := os.WriteFile(marker, []byte("recovery evidence"), 0o600); err != nil {
		t.Fatal(err)
	}

	store := new(recordingStateStore)
	runtime := publishLogoutRuntimeForTest(t, 102, store)
	remoteFailure := errors.New("injected remote logout failure")
	removeCalls := 0
	deps := logoutDependenciesForTest(t, stateDir, func(got *nodeRuntime) error {
		if got != runtime {
			t.Fatalf("revoke runtime = %p, want %p", got, runtime)
		}
		return remoteFailure
	})
	deps.removeAll = func(string) error {
		removeCalls++
		return nil
	}

	result, err := logoutWithDependencies(runtime.token, "{}", deps)
	if !errors.Is(err, ErrLogoutIndeterminate) || !errors.Is(err, remoteFailure) {
		t.Fatalf("logout error = %v, want indeterminate remote failure", err)
	}
	if !result.Started || result.NoState {
		t.Fatalf("logout result = %+v, want started without noState", result)
	}
	if currentRuntime() != nil {
		t.Fatal("indeterminate logout left the mutated runtime current")
	}
	if got := store.closeCalls.Load(); got != 1 {
		t.Fatalf("store close calls = %d, want 1", got)
	}
	if removeCalls != 0 {
		t.Fatalf("local remove calls = %d after failed logout, want 0", removeCalls)
	}
	if got, readErr := os.ReadFile(marker); readErr != nil || string(got) != "recovery evidence" {
		t.Fatalf("failed logout mutated recovery evidence: contents=%q err=%v", got, readErr)
	}
}

func TestLogout_DispositionDoesNotClaimAnUnmatchedClose(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	runtime := publishLogoutRuntimeForTest(t, 110, new(recordingStateStore))
	remoteFailure := errors.New("injected remote logout failure")
	closeFailure := errors.New("injected unmatched close")
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		return remoteFailure
	})
	deps.closeRuntime = func(token uint64) (RuntimeCloseResult, error) {
		return RuntimeCloseResult{Token: token}, closeFailure
	}

	result, err := logoutWithDependencies(runtime.token, "{}", deps)
	if !errors.Is(err, ErrLogoutIndeterminate) ||
		!errors.Is(err, remoteFailure) ||
		!errors.Is(err, closeFailure) {
		t.Fatalf("logout error = %v, want remote and close failures", err)
	}
	if result.Started {
		t.Fatalf("logout result = %+v, must not claim an unmatched close", result)
	}
	if currentRuntime() != runtime {
		t.Fatal("test close unexpectedly detached the runtime")
	}
}

func TestLogout_ConfirmedSuccessRevokesThenClosesThenRemoves(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	events := []string{}
	store := &recordingStateStore{onClose: func() { events = append(events, "close") }}
	runtime := publishLogoutRuntimeForTest(t, 103, store)
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		events = append(events, "remote")
		return nil
	})
	deps.removeAll = func(path string) error {
		events = append(events, "remove")
		return os.RemoveAll(path)
	}

	result, err := logoutWithDependencies(runtime.token, "{}", deps)
	if err != nil {
		t.Fatalf("logoutWithDependencies: %v", err)
	}
	if !result.Started || !result.NoState {
		t.Fatalf("logout result = %+v, want started and noState", result)
	}
	if got := fmt.Sprint(events); got != "[remote close remove]" {
		t.Fatalf("logout order = %s, want [remote close remove]", got)
	}
	if _, statErr := os.Stat(stateDir); !os.IsNotExist(statErr) {
		t.Fatalf("confirmed logout retained state directory: %v", statErr)
	}
}

func TestLogout_PartialStateRemovalPoisonsReplacementAdmission(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	const token uint64 = 111
	runtime := publishLogoutRuntimeForTest(t, token, new(recordingStateStore))
	removeFailure := errors.New("injected partial remove failure")
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error { return nil })
	deps.removeAll = func(string) error { return removeFailure }

	result, err := logoutWithDependencies(runtime.token, "{}", deps)
	if !errors.Is(err, ErrRuntimeCleanupFailed) || !errors.Is(err, removeFailure) {
		t.Fatalf("logout error = %v, want typed partial-removal failure", err)
	}
	if !result.Started || result.NoState || !result.CleanupFailed {
		t.Fatalf("logout result = %+v, want started without confirmed noState", result)
	}
	if _, _, reserveErr := runtimes.reserve(112, runtimeConfig{}); !errors.Is(reserveErr, ErrRuntimeCleanupFailed) {
		t.Fatalf("replacement reserve error = %v, want ErrRuntimeCleanupFailed", reserveErr)
	}
}

func TestLogout_BlocksReplacementAndRescueUntilStateDispositionCompletes(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	const logoutToken uint64 = 106
	runtime := publishLogoutRuntimeForTest(t, logoutToken, new(recordingStateStore))
	enteredRevoke := make(chan *nodeRuntime)
	releaseRevoke := make(chan struct{})
	enteredRemove := make(chan struct{})
	releaseRemove := make(chan struct{})
	deps := logoutDependenciesForTest(t, stateDir, func(got *nodeRuntime) error {
		enteredRevoke <- got
		<-releaseRevoke
		return nil
	})
	deps.removeAll = func(path string) error {
		close(enteredRemove)
		<-releaseRemove
		return os.RemoveAll(path)
	}

	type logoutOutcome struct {
		result LogoutResult
		err    error
	}
	logoutDone := make(chan logoutOutcome, 1)
	go func() {
		result, err := logoutWithDependencies(logoutToken, "network-snapshot", deps)
		logoutDone <- logoutOutcome{result: result, err: err}
	}()
	if got := <-enteredRevoke; got != runtime {
		t.Fatalf("revoke runtime = %p, want %p", got, runtime)
	}

	if _, _, err := runtimes.reserve(107, runtimeConfig{}); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("replacement reserve during remote revoke = %v, want ErrLifecycleBusy", err)
	}
	close(releaseRevoke)
	<-enteredRemove
	if currentRuntime() != nil {
		t.Fatal("logout runtime remained current after close")
	}
	if _, _, err := runtimes.reserve(108, runtimeConfig{}); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("replacement reserve during state removal = %v, want ErrLifecycleBusy", err)
	}

	type abandonOutcome struct {
		result RuntimeCloseResult
		err    error
	}
	abandonDone := make(chan abandonOutcome, 1)
	go func() {
		result, err := AbandonRuntime(logoutToken)
		abandonDone <- abandonOutcome{result: result, err: err}
	}()
	for {
		runtimes.mu.Lock()
		_, observed := runtimes.abandonedTokens[logoutToken]
		runtimes.mu.Unlock()
		if observed {
			break
		}
		goruntime.Gosched()
	}
	select {
	case outcome := <-abandonDone:
		t.Fatalf("rescue returned before state disposition: %+v", outcome)
	default:
	}

	close(releaseRemove)
	outcome := <-logoutDone
	if outcome.err != nil || !outcome.result.Started || !outcome.result.NoState {
		t.Fatalf("logout outcome = (%+v, %v), want confirmed cleanup", outcome.result, outcome.err)
	}
	abandoned := <-abandonDone
	if abandoned.err != nil || !abandoned.result.Matched || !abandoned.result.Started || abandoned.result.Pending {
		t.Fatalf("rescue outcome = (%+v, %v), want joined logout", abandoned.result, abandoned.err)
	}

	candidate, active, err := runtimes.reserve(109, runtimeConfig{})
	if err != nil || candidate == nil || active != nil {
		t.Fatalf("replacement reserve after disposition = (%v, %v, %v), want candidate", candidate, active, err)
	}
	runtimes.release(candidate, nil)
}

func TestLogout_ReconstructsRuntimeAfterDown(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	events := []string{}
	store := &recordingStateStore{onClose: func() { events = append(events, "close") }}
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		events = append(events, "remote")
		return nil
	})
	deps.startRuntime = func(token uint64, config runtimeConfig, snapshot string) (uint64, error) {
		events = append(events, "start")
		wantConfig := runtimeConfig{
			hostname:   "saved-node",
			controlURL: "https://control.example/",
			ephemeral:  true,
		}
		if config != wantConfig {
			t.Fatalf("temporary logout config = %+v, want %+v", config, wantConfig)
		}
		if snapshot != "network-snapshot" {
			t.Fatalf("host snapshot = %q, want network-snapshot", snapshot)
		}
		publishLogoutRuntimeForTest(t, token, store)
		return token, nil
	}
	deps.removeAll = func(path string) error {
		events = append(events, "remove")
		return os.RemoveAll(path)
	}

	result, err := logoutWithDependencies(104, "network-snapshot", deps)
	if err != nil {
		t.Fatalf("logoutWithDependencies: %v", err)
	}
	if !result.Started || !result.NoState {
		t.Fatalf("logout result = %+v, want started and noState", result)
	}
	if got := fmt.Sprint(events); got != "[start remote close remove]" {
		t.Fatalf("logout order = %s, want [start remote close remove]", got)
	}
}

func TestLogout_IdleLegacyStateWithoutRecoverableConfigFailsClosed(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(stateDir, "state.db")
	if err := os.WriteFile(marker, []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	remoteCalls := 0
	startCalls := 0
	removeCalls := 0
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		remoteCalls++
		return nil
	})
	deps.loadRuntimeConfig = lastRuntimeConfig
	deps.startRuntime = func(uint64, runtimeConfig, string) (uint64, error) {
		startCalls++
		return 0, nil
	}
	deps.removeAll = func(string) error {
		removeCalls++
		return nil
	}

	result, err := logoutWithDependencies(105, "network-snapshot", deps)
	if !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("logout error = %v, want recoverable-config failure", err)
	}
	if result.Started || result.NoState {
		t.Fatalf("logout result = %+v, want untouched legacy state", result)
	}
	if startCalls != 0 || remoteCalls != 0 || removeCalls != 0 {
		t.Fatalf("unsafe logout work ran: start=%d remote=%d remove=%d", startCalls, remoteCalls, removeCalls)
	}
	if got, readErr := os.ReadFile(marker); readErr != nil || string(got) != "state" {
		t.Fatalf("fail-closed logout mutated state: contents=%q err=%v", got, readErr)
	}
}

// --- jsonError tests ---

func TestJsonError_SimpleMessage(t *testing.T) {
	err := fmt.Errorf("something went wrong")
	result := jsonError(err)

	var parsed map[string]string
	if e := json.Unmarshal([]byte(result), &parsed); e != nil {
		t.Fatalf("jsonError produced invalid JSON: %v\nResult: %s", e, result)
	}

	if parsed["error"] != "something went wrong" {
		t.Errorf("error message = %q, want %q", parsed["error"], "something went wrong")
	}
}

func TestJsonError_SpecialCharacters(t *testing.T) {
	// This was the bug: fmt.Sprintf with %v would produce invalid JSON
	// if the error contained quotes, backslashes, or newlines.
	err := fmt.Errorf(`failed: "file not found" at path\nline2`)
	result := jsonError(err)

	var parsed map[string]string
	if e := json.Unmarshal([]byte(result), &parsed); e != nil {
		t.Fatalf("jsonError produced invalid JSON for special chars: %v\nResult: %s", e, result)
	}

	if !strings.Contains(parsed["error"], "file not found") {
		t.Errorf("error message should contain 'file not found', got %q", parsed["error"])
	}
}

func TestHttpBind_RejectsInvalidTailnetPort(t *testing.T) {
	if _, err := HttpBind(-1); err == nil {
		t.Fatal("HttpBind with invalid tailnet port succeeded, want error")
	}
}

func TestHTTPResponseHeadRoundTrips(t *testing.T) {
	var buf bytes.Buffer
	original := httpResponseHead{
		StatusCode: 201,
		Headers: map[string][]string{
			"Content-Type": {"text/plain"},
			"X-Test":       {"a", "b"},
		},
		ContentLength: 5,
	}

	if err := writeHTTPResponseHead(&buf, original); err != nil {
		t.Fatalf("writeHTTPResponseHead: %v", err)
	}

	got, err := readHTTPResponseHead(&buf)
	if err != nil {
		t.Fatalf("readHTTPResponseHead: %v", err)
	}
	if got.StatusCode != original.StatusCode {
		t.Fatalf("StatusCode = %d, want %d", got.StatusCode, original.StatusCode)
	}
	if got.ContentLength != original.ContentLength {
		t.Fatalf("ContentLength = %d, want %d", got.ContentLength, original.ContentLength)
	}
	if fmt.Sprint(got.Headers) != fmt.Sprint(original.Headers) {
		t.Fatalf("Headers = %#v, want %#v", got.Headers, original.Headers)
	}
}

// --- Stop tests ---

func TestStop_WhenNotStarted(t *testing.T) {
	// Should not panic when called without Start
	Stop()
}

// --- Start behavior tests ---

func TestStart_NoOpWithoutAuthKey(t *testing.T) {
	configureFreshStateRootForTest(t)
	withLiveServer(t, &tsnet.Server{}, runtimeConfig{
		hostname:   "host",
		controlURL: "https://control",
	})

	if err := Start("host", "", "https://control", false); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
}

func TestStart_AppliesEphemeralFlag(t *testing.T) {
	Stop()
	t.Cleanup(Stop)
	t.Setenv("TS_LOGS_DIR", "embedding-app-log-dir")

	stateDir := configureFreshStateRootForTest(t)
	if err := Start("ephemeral-test", "", "", true); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}

	runtime := currentRuntime()
	if runtime == nil {
		t.Fatal("Start did not commit a server")
	}
	if !runtime.server.Ephemeral {
		t.Fatal("Start did not apply Ephemeral=true to tsnet.Server")
	}
	if got := os.Getenv("TS_LOGS_DIR"); got != "embedding-app-log-dir" {
		t.Fatalf("TS_LOGS_DIR = %q after Start, want prior value restored", got)
	}
	if got := os.Getenv("TS_ENABLE_RAW_DISCO"); got != "false" {
		t.Fatalf("TS_ENABLE_RAW_DISCO = %q, want compatibility value false", got)
	}
	if info, err := os.Stat(filepath.Join(stateDir, "logs")); err != nil || !info.IsDir() {
		t.Fatalf("runtime log directory missing: info=%v err=%v", info, err)
	}
}

func TestStart_RuntimeCloseClosesListeners(t *testing.T) {
	oldLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	httpBindingMu.Lock()
	httpBindingRegistry[99] = &httpBindingState{
		binding:  HttpBinding{ID: 99, TailnetPort: 80},
		ln:       oldLn,
		requests: make(chan *HttpIncomingRequest, 1),
		done:     make(chan struct{}),
	}
	httpBindingMu.Unlock()

	withLiveServer(t, nil, runtimeConfig{})
	Stop()

	httpBindingMu.Lock()
	_, stillRegistered := httpBindingRegistry[99]
	httpBindingMu.Unlock()
	if stillRegistered {
		t.Error("HTTP binding should be removed by runtime close")
	}

	// Old listeners should be closed — Accept returns immediately with an
	// error on a closed listener, so no deadline is needed.
	if _, err := oldLn.Accept(); err == nil {
		t.Error("old HTTP binding listener should be closed")
	}
}

// --- LogLevel tests ---

func TestLogLevel_DefaultIsSilent(t *testing.T) {
	level := atomic.LoadInt32(&LogLevel)
	if level != 0 {
		t.Errorf("default LogLevel = %d, want 0 (silent)", level)
	}
}

func TestLogLevel_AtomicSetGet(t *testing.T) {
	// Save and restore
	orig := atomic.LoadInt32(&LogLevel)
	defer atomic.StoreInt32(&LogLevel, orig)

	atomic.StoreInt32(&LogLevel, 2)
	if got := atomic.LoadInt32(&LogLevel); got != 2 {
		t.Errorf("LogLevel after set to 2 = %d", got)
	}

	atomic.StoreInt32(&LogLevel, 0)
	if got := atomic.LoadInt32(&LogLevel); got != 0 {
		t.Errorf("LogLevel after set to 0 = %d", got)
	}
}
