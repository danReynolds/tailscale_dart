package tailscale

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// LogLevel controls logging verbosity. 0=silent, 1=error, 2=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var (
	mu sync.Mutex // protects srv and store

	srv   *tsnet.Server
	store *SQLiteStore // package-owned; tsnet.Server doesn't close its Store, so we do in stopLocked
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
	closeAllTcpFdListeners()
	closeAllHttpBindings()

	if srv != nil {
		srv.Close()
		srv = nil
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
	logDir := stateDir + "/logs"
	if err := os.MkdirAll(logDir, 0700); err != nil {
		return fmt.Errorf("failed to create log dir: %v", err)
	}
	// Android apps do not have the desktop/server filesystem locations that
	// Tailscale's log policy probes by default. Point it at app-owned storage
	// before tsnet starts so internal logging never falls through to panic.
	os.Setenv("TS_LOGS_DIR", logDir)

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

	// If we fail before committing newSrv/newStore to package state,
	// release their resources. The named return `err` is the signal — any
	// `return ..., err` with a non-nil error triggers cleanup.
	defer func() {
		if err == nil {
			return
		}
		newSrv.Close()
		newStore.Close()
	}()

	if startErr := newSrv.Start(); startErr != nil {
		return fmt.Errorf("failed to start tsnet: %v", startErr)
	}

	// Commit to package state only after every allocation succeeded.
	srv = newSrv
	store = newStore
	return nil
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
