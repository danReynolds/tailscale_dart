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
	_ string,
	revoke func(*nodeRuntime) error,
) runtimeLogoutDependencies {
	t.Helper()
	return runtimeLogoutDependencies{
		prepareIdleRuntime: func(uint64, string) (uint64, error) {
			t.Fatal("unexpected temporary logout runtime")
			return 0, nil
		},
		revokeNodeKey: revoke,
		closeRuntime:  closeRuntimeForLogout,
	}
}

func TestLogout_IdleWithoutPreparedStateFailsClosed(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	remoteCalls := 0
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		remoteCalls++
		return nil
	})

	deps.prepareIdleRuntime = func(uint64, string) (uint64, error) {
		return 0, ErrRuntimeStale
	}
	result, err := logoutWithDependencies(101, "{}", deps)
	if !errors.Is(err, ErrRuntimeStale) {
		t.Fatalf("logoutWithDependencies error = %v, want ErrRuntimeStale", err)
	}
	if result.NoState || result.Started {
		t.Fatalf("logout result = %+v, want untouched idle state", result)
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
	deps.prepareIdleRuntime = func(uint64, string) (uint64, error) {
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
	marker := filepath.Join(stateDir, encryptedStateFileName)
	if err := os.WriteFile(marker, []byte("recovery evidence"), 0o600); err != nil {
		t.Fatal(err)
	}

	store := new(recordingStateStore)
	runtime := publishLogoutRuntimeForTest(t, 102, store)
	remoteFailure := errors.New("injected remote logout failure")
	deps := logoutDependenciesForTest(t, stateDir, func(got *nodeRuntime) error {
		if got != runtime {
			t.Fatalf("revoke runtime = %p, want %p", got, runtime)
		}
		return remoteFailure
	})

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
	if got, readErr := os.ReadFile(marker); readErr != nil || string(got) != "recovery evidence" {
		t.Fatalf("failed logout mutated recovery evidence: contents=%q err=%v", got, readErr)
	}
}

func TestLogout_DispositionDoesNotClaimAnUnmatchedClose(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, encryptedStateFileName), []byte("state"), 0o600); err != nil {
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

func TestLogout_ConfirmedSuccessRevokesThenClosesAndPreservesStore(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(stateDir, encryptedStateFileName)
	if err := os.WriteFile(marker, []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	events := []string{}
	store := &recordingStateStore{onClose: func() { events = append(events, "close") }}
	runtime := publishLogoutRuntimeForTest(t, 103, store)
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		events = append(events, "remote")
		return nil
	})

	result, err := logoutWithDependencies(runtime.token, "{}", deps)
	if err != nil {
		t.Fatalf("logoutWithDependencies: %v", err)
	}
	if !result.Started || !result.EmitStopped || !result.NoState {
		t.Fatalf("logout result = %+v, want public stop and noState", result)
	}
	if got := fmt.Sprint(events); got != "[remote close]" {
		t.Fatalf("logout order = %s, want [remote close]", got)
	}
	if got, readErr := os.ReadFile(marker); readErr != nil || string(got) != "state" {
		t.Fatalf("confirmed logout removed the StateStore container: contents=%q err=%v", got, readErr)
	}
}

func TestLogout_BlocksReplacementAndRescueUntilRuntimeCloseCompletes(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, encryptedStateFileName), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	const logoutToken uint64 = 106
	runtime := publishLogoutRuntimeForTest(t, logoutToken, new(recordingStateStore))
	enteredRevoke := make(chan *nodeRuntime)
	releaseRevoke := make(chan struct{})
	enteredClose := make(chan struct{})
	releaseClose := make(chan struct{})
	deps := logoutDependenciesForTest(t, stateDir, func(got *nodeRuntime) error {
		enteredRevoke <- got
		<-releaseRevoke
		return nil
	})
	closeRuntime := deps.closeRuntime
	deps.closeRuntime = func(token uint64) (RuntimeCloseResult, error) {
		result, err := closeRuntime(token)
		close(enteredClose)
		<-releaseClose
		return result, err
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
	<-enteredClose
	if currentRuntime() != nil {
		t.Fatal("logout runtime remained current after close")
	}
	if _, _, err := runtimes.reserve(108, runtimeConfig{}); !errors.Is(err, ErrLifecycleBusy) {
		t.Fatalf("replacement reserve during logout close = %v, want ErrLifecycleBusy", err)
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
		t.Fatalf("rescue returned before logout close completed: %+v", outcome)
	default:
	}

	close(releaseClose)
	outcome := <-logoutDone
	if outcome.err != nil || !outcome.result.Started || !outcome.result.NoState {
		t.Fatalf("logout outcome = (%+v, %v), want confirmed cleanup", outcome.result, outcome.err)
	}
	abandoned := <-abandonDone
	if abandoned.err != nil || !abandoned.result.Matched || !abandoned.result.Started || abandoned.result.Pending {
		t.Fatalf("rescue outcome = (%+v, %v), want joined logout", abandoned.result, abandoned.err)
	}
	if got, readErr := os.ReadFile(filepath.Join(stateDir, encryptedStateFileName)); readErr != nil || string(got) != "state" {
		t.Fatalf("logout removed the StateStore container: contents=%q err=%v", got, readErr)
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
	if err := os.WriteFile(filepath.Join(stateDir, encryptedStateFileName), []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	events := []string{}
	store := &recordingStateStore{onClose: func() { events = append(events, "close") }}
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		events = append(events, "remote")
		return nil
	})
	deps.prepareIdleRuntime = func(token uint64, snapshot string) (uint64, error) {
		events = append(events, "start")
		if snapshot != "network-snapshot" {
			t.Fatalf("host snapshot = %q, want network-snapshot", snapshot)
		}
		publishLogoutRuntimeForTest(t, token, store)
		return token, nil
	}
	result, err := logoutWithDependencies(104, "network-snapshot", deps)
	if err != nil {
		t.Fatalf("logoutWithDependencies: %v", err)
	}
	if !result.Started || result.EmitStopped || !result.NoState {
		t.Fatalf("logout result = %+v, want hidden temporary close and noState", result)
	}
	if got := fmt.Sprint(events); got != "[start remote close]" {
		t.Fatalf("logout order = %s, want [start remote close]", got)
	}
	if got, readErr := os.ReadFile(filepath.Join(stateDir, encryptedStateFileName)); readErr != nil || string(got) != "state" {
		t.Fatalf("idle logout removed the StateStore container: contents=%q err=%v", got, readErr)
	}
}

func TestLogout_IdlePreparationFailureIsRemoteFree(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(stateDir, encryptedStateFileName)
	if err := os.WriteFile(marker, []byte("state"), 0o600); err != nil {
		t.Fatal(err)
	}

	remoteCalls := 0
	startCalls := 0
	deps := logoutDependenciesForTest(t, stateDir, func(*nodeRuntime) error {
		remoteCalls++
		return nil
	})
	deps.prepareIdleRuntime = func(uint64, string) (uint64, error) {
		startCalls++
		return 0, ErrLegacyStateUnsupported
	}

	result, err := logoutWithDependencies(105, "network-snapshot", deps)
	if !errors.Is(err, ErrLegacyStateUnsupported) {
		t.Fatalf("logout error = %v, want prepared-state failure", err)
	}
	if result.Started || result.NoState {
		t.Fatalf("logout result = %+v, want untouched legacy state", result)
	}
	if startCalls != 1 || remoteCalls != 0 {
		t.Fatalf("unsafe logout work ran: prepare=%d remote=%d", startCalls, remoteCalls)
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
	if _, err := HttpBind(0, -1); err == nil {
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
	if err := Start("ephemeral-test", "test-auth-key", "", true); err != nil {
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
	scratch := runtime.scratchDirectory()
	if info, err := os.Stat(scratch); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("ephemeral scratch invalid: path=%q info=%v err=%v", scratch, info, err)
	}
	if _, err := os.Lstat(stateDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("ephemeral startup created persistent state: %v", err)
	}
}

func TestStart_RuntimeCloseClosesListeners(t *testing.T) {
	oldLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	withLiveServer(t, nil, runtimeConfig{})
	runtime := currentRuntime()
	if !runtime.fd.httpBindings.commit(liveGate(t), 99, &httpBindingState{
		binding:  HttpBinding{ID: 99, TailnetPort: 80},
		ln:       oldLn,
		requests: make(chan *HttpIncomingRequest, 1),
		done:     make(chan struct{}),
	}) {
		t.Fatal("live binding registration must be accepted")
	}
	Stop()

	if _, stillRegistered := runtime.fd.httpBindings.get(99); stillRegistered {
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

	atomic.StoreInt32(&LogLevel, 1)
	if got := atomic.LoadInt32(&LogLevel); got != 1 {
		t.Errorf("LogLevel after set to 1 = %d", got)
	}

	atomic.StoreInt32(&LogLevel, 0)
	if got := atomic.LoadInt32(&LogLevel); got != 0 {
		t.Errorf("LogLevel after set to 0 = %d", got)
	}
}
