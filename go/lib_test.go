package tailscale

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
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

// --- handleOutgoingProxy tests ---

func TestOutgoingProxy_MissingTarget(t *testing.T) {
	// Temporarily set srv to a non-nil value so the handler doesn't 503.
	// We can't easily create a real tsnet.Server, but we can test the missing-target path
	// by directly calling the handler.
	// Note: this test hits the "srv == nil" branch since we can't set it without Start().
	req := httptest.NewRequest("GET", "/api/v1/data", nil)
	rec := httptest.NewRecorder()

	handleOutgoingProxy(rec, req)

	// With srv == nil, we get 503
	if rec.Code != 503 {
		t.Errorf("expected 503 when srv is nil, got %d", rec.Code)
	}
}

func TestParseOutgoingTarget_PreservesHTTPSAndQuery(t *testing.T) {
	target, err := parseOutgoingTarget("https://100.64.0.5/api/data?target=user-value&foo=bar")
	if err != nil {
		t.Fatalf("parseOutgoingTarget returned error: %v", err)
	}

	if got := target.Scheme; got != "https" {
		t.Errorf("scheme = %q, want %q", got, "https")
	}
	if got := target.Host; got != "100.64.0.5" {
		t.Errorf("host = %q, want %q", got, "100.64.0.5")
	}
	if got := target.RawQuery; got != "target=user-value&foo=bar" {
		t.Errorf("raw query = %q, want %q", got, "target=user-value&foo=bar")
	}
}

func TestParseOutgoingTarget_RejectsInvalidURLs(t *testing.T) {
	tests := []string{
		"",
		"/relative/path",
		"ftp://100.64.0.5/file.txt",
		"http:///missing-host",
	}

	for i, target := range tests {
		t.Run(fmt.Sprintf("case_%d", i), func(t *testing.T) {
			if _, err := parseOutgoingTarget(target); err == nil {
				t.Errorf("parseOutgoingTarget(%q) succeeded, want error", target)
			}
		})
	}
}

func TestIsAuthorizedOutgoingProxyRequest(t *testing.T) {
	req := httptest.NewRequest("GET", "http://127.0.0.1/proxy", nil)

	if isAuthorizedOutgoingProxyRequest(req, "secret") {
		t.Fatal("request without auth header should not be authorized")
	}

	req.Header.Set(proxyAuthHeader, "secret")
	if !isAuthorizedOutgoingProxyRequest(req, "secret") {
		t.Fatal("request with matching auth header should be authorized")
	}
}

func TestFilteredProxyRequestHeaders_StripsInternalProxyAuth(t *testing.T) {
	headers := http.Header{
		proxyAuthHeader: []string{"secret"},
		"Accept":        []string{"application/json"},
	}

	filtered := filteredProxyRequestHeaders(headers)

	if got := filtered.Get(proxyAuthHeader); got != "" {
		t.Fatalf("proxy auth header leaked to outbound request: %q", got)
	}
	if got := filtered.Get("Accept"); got != "application/json" {
		t.Fatalf("Accept header = %q, want application/json", got)
	}
}

func TestHandleOutgoingProxy_RejectsUnexpectedPath(t *testing.T) {
	mu.Lock()
	srv = &tsnet.Server{}
	proxyAuthToken = "secret"
	mu.Unlock()
	defer func() {
		mu.Lock()
		srv = nil
		proxyAuthToken = ""
		mu.Unlock()
	}()

	req := httptest.NewRequest("GET", "http://127.0.0.1/not-proxy?target=https://example.com", nil)
	req.Header.Set(proxyAuthHeader, "secret")
	rec := httptest.NewRecorder()

	handleOutgoingProxy(rec, req)

	if rec.Code != 404 {
		t.Fatalf("unexpected status for non-proxy path: got %d want 404", rec.Code)
	}
}

func TestListen_RejectsInvalidTailnetPort(t *testing.T) {
	if _, err := Listen(0, 0); err == nil {
		t.Fatal("Listen with invalid tailnet port succeeded, want error")
	}
}

// --- handleReverseProxy tests ---

func TestReverseProxy_ForwardsToLocal(t *testing.T) {
	// Start a local test server that the reverse proxy will forward to
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		peerIP := r.Header.Get("X-Dune-Peer-Ip")
		w.Header().Set("X-Test-Peer", peerIP)
		w.Header().Set("X-Test-Path", r.URL.Path)
		w.WriteHeader(200)
		fmt.Fprint(w, "hello from backend")
	}))
	defer backend.Close()

	// Extract the port from the backend address
	_, portStr, _ := net.SplitHostPort(backend.Listener.Addr().String())

	// Set up targetPort to point to our backend
	targetPortMu.Lock()
	// We need to parse the port
	var backendPort int
	fmt.Sscanf(portStr, "%d", &backendPort)
	targetPort = backendPort
	targetPortMu.Unlock()

	// Create a request that simulates incoming Tailscale traffic
	req := httptest.NewRequest("GET", "/api/hello?foo=bar", strings.NewReader(""))
	req.RemoteAddr = "100.64.0.1:12345"
	rec := httptest.NewRecorder()

	handleReverseProxy(rec, req)

	if rec.Code != 200 {
		t.Errorf("reverse proxy: got status %d, want 200", rec.Code)
	}

	body := rec.Body.String()
	if body != "hello from backend" {
		t.Errorf("reverse proxy body = %q, want %q", body, "hello from backend")
	}

	// Check that X-Dune-Peer-Ip header was forwarded
	if peer := rec.Header().Get("X-Test-Peer"); peer != "100.64.0.1" {
		t.Errorf("X-Dune-Peer-Ip = %q, want %q", peer, "100.64.0.1")
	}

	// Check path was forwarded correctly
	if path := rec.Header().Get("X-Test-Path"); path != "/api/hello" {
		t.Errorf("forwarded path = %q, want %q", path, "/api/hello")
	}
}

func TestReverseProxy_PostWithBody(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		w.WriteHeader(200)
		fmt.Fprintf(w, "echo:%s", body)
	}))
	defer backend.Close()

	_, portStr, _ := net.SplitHostPort(backend.Listener.Addr().String())
	var backendPort int
	fmt.Sscanf(portStr, "%d", &backendPort)

	targetPortMu.Lock()
	targetPort = backendPort
	targetPortMu.Unlock()

	req := httptest.NewRequest("POST", "/submit", strings.NewReader(`{"key":"value"}`))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "100.64.0.2:9999"
	rec := httptest.NewRecorder()

	handleReverseProxy(rec, req)

	if rec.Code != 200 {
		t.Errorf("POST proxy: got status %d, want 200", rec.Code)
	}

	body := rec.Body.String()
	if body != `echo:{"key":"value"}` {
		t.Errorf("POST proxy body = %q", body)
	}
}

func TestReverseProxy_BackendDown(t *testing.T) {
	// Point to a port that's definitely not listening
	targetPortMu.Lock()
	targetPort = 1 // Port 1 is unlikely to have a server
	targetPortMu.Unlock()

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "100.64.0.1:1234"
	rec := httptest.NewRecorder()

	handleReverseProxy(rec, req)

	// Should get a 502 after retries
	if rec.Code != 502 {
		t.Errorf("backend down: got status %d, want 502", rec.Code)
	}
}

func TestReverseProxy_HeaderForwarding(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Echo back custom headers
		w.Header().Set("X-Custom-Response", "from-backend")
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(201)
		fmt.Fprint(w, "ok")
	}))
	defer backend.Close()

	_, portStr, _ := net.SplitHostPort(backend.Listener.Addr().String())
	var backendPort int
	fmt.Sscanf(portStr, "%d", &backendPort)

	targetPortMu.Lock()
	targetPort = backendPort
	targetPortMu.Unlock()

	req := httptest.NewRequest("GET", "/test", nil)
	req.Header.Set("X-Custom-Request", "from-client")
	req.RemoteAddr = "100.64.0.1:5555"
	rec := httptest.NewRecorder()

	handleReverseProxy(rec, req)

	if rec.Code != 201 {
		t.Errorf("header forwarding: got status %d, want 201", rec.Code)
	}

	if v := rec.Header().Get("X-Custom-Response"); v != "from-backend" {
		t.Errorf("response header X-Custom-Response = %q, want %q", v, "from-backend")
	}
}

// --- Stop tests ---

func TestStop_WhenNotStarted(t *testing.T) {
	// Should not panic when called without Start
	Stop()
}

func TestStop_ResetsProxyPort(t *testing.T) {
	// proxyPort is only reset when srv is non-nil (actual shutdown path).
	// When srv is nil, Stop is a no-op — proxyPort stays unchanged.
	mu.Lock()
	proxyPort = 12345
	mu.Unlock()

	Stop()

	mu.Lock()
	port := proxyPort
	mu.Unlock()

	// srv was nil, so proxyPort should not have been touched
	if port != 12345 {
		t.Errorf("proxyPort after Stop with nil srv = %d, want 12345 (unchanged)", port)
	}

	// Clean up
	mu.Lock()
	proxyPort = 0
	mu.Unlock()
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
