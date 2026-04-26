package tailscale

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// --- HasState tests ---

func TestHasState_NoDir(t *testing.T) {
	if HasState("/nonexistent/path") {
		t.Error("HasState should return false for nonexistent directory")
	}
}

func TestHasState_EmptyDB(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "state.db")

	// Create an empty store (no machine key written)
	store, err := NewSQLiteStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	store.Close()

	if HasState(dir) {
		t.Error("HasState should return false for empty database")
	}
}

func TestHasState_WithMachineKey(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "state.db")

	store, err := NewSQLiteStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.WriteState(ipn.MachineKeyStateKey, []byte("fake-machine-key")); err != nil {
		t.Fatal(err)
	}
	store.Close()

	if !HasState(dir) {
		t.Error("HasState should return true when machine key exists")
	}
}

// --- Logout tests ---

func TestLogout_RemovesDir(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "tailscale_state")
	os.MkdirAll(stateDir, 0700)

	// Write a file so the dir isn't empty
	os.WriteFile(filepath.Join(stateDir, "state.db"), []byte("data"), 0600)

	if err := Logout(stateDir); err != nil {
		t.Fatalf("Logout returned error: %v", err)
	}

	if _, err := os.Stat(stateDir); !os.IsNotExist(err) {
		t.Errorf("Logout should remove the state directory, but it still exists")
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
	mu.Lock()
	srv = &tsnet.Server{}
	mu.Unlock()
	defer func() {
		mu.Lock()
		srv = nil
		mu.Unlock()
	}()

	if err := Start("host", "", "https://control", t.TempDir()); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
}

func TestStart_StopLockedClosesListeners(t *testing.T) {
	oldLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	srv = nil
	mu.Unlock()
	httpBindingMu.Lock()
	httpBindingRegistry[99] = &httpBindingState{
		binding:  HttpBinding{ID: 99, TailnetPort: 80},
		ln:       oldLn,
		requests: make(chan *HttpIncomingRequest, 1),
		done:     make(chan struct{}),
	}
	httpBindingMu.Unlock()

	mu.Lock()
	stopLocked()
	mu.Unlock()

	httpBindingMu.Lock()
	_, stillRegistered := httpBindingRegistry[99]
	httpBindingMu.Unlock()
	if stillRegistered {
		t.Error("HTTP binding should be removed after stopLocked")
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
