package tailscale

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// LogLevel controls logging verbosity. 0=silent, 1=error, 2=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var (
	mu sync.Mutex // protects srv, store, reverseProxyLn

	srv            *tsnet.Server
	store          *SQLiteStore // package-owned; tsnet.Server doesn't close its Store, so we do in stopLocked

	reverseProxyLn          net.Listener
	reverseProxyTailnetPort int

	// targetPort is the local Dart port we forward to.
	targetPort   int
	targetPortMu sync.Mutex

	// reverseClient is reused across reverse-proxy requests for connection pooling.
	reverseClient = &http.Client{
		Timeout: 30 * time.Second,
	}
)

const (
	localForwardMaxAttempts = 3
	localForwardRetryDelay  = 150 * time.Millisecond
)

// HasState checks if the state directory contains a valid machine key.
func HasState(stateDir string) bool {
	statePath := stateDir + "/state.db"
	store, err := NewSQLiteStore(statePath)
	if err != nil {
		return false
	}
	defer store.Close()

	val, err := store.ReadState(ipn.MachineKeyStateKey)
	if err != nil {
		return false
	}
	return len(val) > 0
}

// Logout stops the server and removes the state directory.
func Logout(stateDir string) error {
	if strings.TrimSpace(stateDir) == "" {
		return fmt.Errorf("state dir is empty")
	}

	Stop()
	if err := os.RemoveAll(stateDir); err != nil {
		return fmt.Errorf("failed to remove state dir: %w", err)
	}
	// Post-logout the node has no credentials and — per NodeState.parse on
	// the Dart side — should report NoState. Publish that explicitly so
	// stream subscribers see the transition; if `Stop()` above had a live
	// server to tear down it also published Stopped, so the full sequence
	// delivered to Dart is Stopped → NoState (or just NoState if the node
	// was already stopped).
	publishState("NoState")
	return nil
}

// Stop stops the server and closes all listeners.
//
// Publishes `Stopped` to stream subscribers iff there was actually a server
// to tear down — tsnet.Server.Close() doesn't emit a terminal state through
// the IPN bus, so without this explicit publish our onStateChange subscribers
// drift from the actual engine state. No-op (and no event) when already
// stopped, to avoid phantom emits for callers that subscribe across
// lifecycle boundaries.
func Stop() {
	mu.Lock()
	wasRunning := srv != nil
	stopLocked()
	mu.Unlock()
	// Publish after releasing the lock to keep the hold time minimal and
	// avoid any reentrancy surprise from the native bridge.
	if wasRunning {
		publishState("Stopped")
	}
}

// stopLocked tears down the server and all listeners. Caller must hold mu.
func stopLocked() {
	closeRuntimeTransportLocked()
	cancelAllHTTPRequests()

	if reverseProxyLn != nil {
		reverseProxyLn.Close()
		reverseProxyLn = nil
	}

	if srv != nil {
		srv.Close()
		srv = nil
		reverseProxyTailnetPort = 0
	}

	// tsnet.Server doesn't own the Store — the caller does — so Close()
	// on srv doesn't close our SQLiteStore. Without this, every up/down
	// cycle leaks a *sql.DB connection pool.
	if store != nil {
		store.Close()
		store = nil
	}
}

// Start initializes the Tailscale node.
func Start(hostname, authKey, controlURL, stateDir string) (err error) {
	mu.Lock()
	defer mu.Unlock()

	if srv != nil {
		if authKey == "" {
			return nil
		}
		// Auth key provided on an already-running server — tear down
		// and restart so the new key is applied. Clear persisted state
		// so tsnet treats it as a fresh node; otherwise the existing
		// NeedsLogin state causes tsnet to call StartLoginInteractive
		// and ignore the auth key.
		if strings.TrimSpace(stateDir) == "" {
			return fmt.Errorf("state dir is empty")
		}
		stopLocked()
		if err := os.RemoveAll(stateDir); err != nil {
			return fmt.Errorf("failed to clear state dir for re-auth: %w", err)
		}
	}

	os.Setenv("TS_ENABLE_RAW_DISCO", "false")

	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return fmt.Errorf("failed to create state dir: %v", err)
	}

	statePath := stateDir + "/state.db"
	newStore, err := NewSQLiteStore(statePath)
	if err != nil {
		return fmt.Errorf("failed to create sqlite store: %v", err)
	}

	newSrv := &tsnet.Server{
		Hostname:   hostname,
		AuthKey:    authKey,
		ControlURL: controlURL,
		Dir:        stateDir,
		Store:      newStore,
		Logf: func(format string, args ...any) {
			if atomic.LoadInt32(&LogLevel) >= 2 {
				log.Printf("TSNET: "+format, args...)
			}
		},
	}

	// If we fail before committing newSrv/newStore to package state, release
	// their resources. The named return `err` is the signal.
	defer func() {
		if err == nil {
			return
		}
		newSrv.Close()
		newStore.Close()
	}()

	if startErr := newSrv.Start(); startErr != nil {
		if strings.Contains(startErr.Error(), "permission denied") || strings.Contains(startErr.Error(), "netlink") {
			logInfo("Ignoring expected Android permission error: %v", startErr)
		} else {
			return fmt.Errorf("failed to start tsnet: %v", startErr)
		}
	}

	// Commit to package state only after every allocation succeeded.
	srv = newSrv
	store = newStore
	ensureRuntimeTransportLocked()

	return nil
}

// Listen starts the reverse proxy that accepts incoming tailnet HTTP traffic on
// tailnetPort and forwards it to a local port. If localPort > 0, traffic is
// forwarded there. If localPort == 0, an ephemeral port is allocated.
// Returns the local port.
func Listen(localPort, tailnetPort int) (int, error) {
	if tailnetPort < 1 || tailnetPort > 65535 {
		return 0, fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}

	mu.Lock()
	s := srv
	alreadyListening := reverseProxyLn != nil
	currentTailnetPort := reverseProxyTailnetPort
	mu.Unlock()

	if s == nil {
		return 0, fmt.Errorf("Listen called before Start")
	}

	// Allocate ephemeral port if needed
	if localPort == 0 {
		tmpLn, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return 0, fmt.Errorf("failed to allocate listen port: %v", err)
		}
		localPort = tmpLn.Addr().(*net.TCPAddr).Port
		tmpLn.Close()
	}

	// Update the target port
	targetPortMu.Lock()
	targetPort = localPort
	targetPortMu.Unlock()

	// If already listening on the requested port, the handler picks up the new targetPort.
	if alreadyListening && currentTailnetPort == tailnetPort {
		return localPort, nil
	}

	if alreadyListening {
		mu.Lock()
		if reverseProxyLn != nil {
			reverseProxyLn.Close()
			reverseProxyLn = nil
			reverseProxyTailnetPort = 0
		}
		mu.Unlock()
	}

	ln, err := s.Listen("tcp", fmt.Sprintf(":%d", tailnetPort))
	if err != nil {
		return 0, fmt.Errorf("failed to listen on tsnet:%d: %v", tailnetPort, err)
	}

	mu.Lock()
	// Re-check srv IDENTITY under lock (not just non-nil): a concurrent
	// Stop() would have nulled srv, but a Stop()+Start() would replace
	// it with a different instance. In either case `ln` is attached to
	// the old `s` we captured before lock — committing it to package
	// state would bind the reverse proxy to a server we no longer own.
	if srv != s {
		mu.Unlock()
		ln.Close()
		return 0, fmt.Errorf("Listen raced with Stop or server replacement")
	}
	if reverseProxyLn != nil {
		mu.Unlock()
		ln.Close()
		return localPort, nil
	}
	reverseProxyLn = ln
	reverseProxyTailnetPort = tailnetPort
	mu.Unlock()

	go http.Serve(ln, http.HandlerFunc(handleReverseProxy))

	return localPort, nil
}

// handleReverseProxy forwards incoming Tailscale traffic to the local Dart server.
func handleReverseProxy(w http.ResponseWriter, r *http.Request) {
	targetPortMu.Lock()
	port := targetPort
	targetPortMu.Unlock()

	target := fmt.Sprintf("http://127.0.0.1:%d", port)
	targetURL := target + r.URL.RequestURI()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", 500)
		return
	}
	r.Body.Close()

	remoteIp, _, remoteIpErr := net.SplitHostPort(r.RemoteAddr)

	var resp *http.Response
	for attempt := 1; attempt <= localForwardMaxAttempts; attempt++ {
		outReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, bytes.NewReader(body))
		if err != nil {
			http.Error(w, "Failed to create proxy request", 500)
			return
		}

		for k, v := range r.Header {
			outReq.Header[k] = append([]string(nil), v...)
		}

		if remoteIpErr == nil {
			outReq.Header.Set("X-Dune-Peer-Ip", remoteIp)
		}

		resp, err = reverseClient.Do(outReq)
		if err == nil {
			break
		}

		if attempt == localForwardMaxAttempts {
			http.Error(w, fmt.Sprintf("Local Forward Error: %v", err), 502)
			return
		}

		time.Sleep(localForwardRetryDelay)
	}
	defer resp.Body.Close()

	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// DuneStatus returns the local-node status JSON from the LocalAPI.
func DuneStatus() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "{}"
	}
	lc, err := s.LocalClient()
	if err != nil {
		return jsonError(err)
	}
	status, err := lc.StatusWithoutPeers(context.Background())
	if err != nil {
		return jsonError(err)
	}
	jsonBytes, err := json.Marshal(status)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

// DunePeers returns the current peer list as JSON.
func DunePeers() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "[]"
	}
	lc, err := s.LocalClient()
	if err != nil {
		return jsonError(err)
	}
	status, err := lc.Status(context.Background())
	if err != nil {
		return jsonError(err)
	}

	peers := make([]*ipnstate.PeerStatus, 0, len(status.Peer))
	for _, peer := range status.Peer {
		peers = append(peers, peer)
	}
	ipnstate.SortPeers(peers)

	jsonBytes, err := json.Marshal(peers)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

func jsonError(err error) string {
	m := map[string]string{"error": err.Error()}
	b, _ := json.Marshal(m)
	return string(b)
}

func logInfo(format string, args ...any) {
	if atomic.LoadInt32(&LogLevel) >= 2 {
		log.Printf("TSNET: "+format, args...)
	}
}
