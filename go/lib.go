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
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// LogLevel controls logging verbosity. 0=silent, 1=error, 2=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var (
	mu sync.Mutex // protects srv, store, and the cached start config below

	srv   *tsnet.Server
	store *SQLiteStore // package-owned; tsnet.Server doesn't close its Store, so we do in stopLocked

	// lastHostname and lastControlURL remember the most recent successful Start
	// so Logout can re-establish a transient client to revoke the node key even
	// when the caller already stopped the server. An empty lastControlURL just
	// means we fall back to a local-only wipe.
	lastHostname   string
	lastControlURL string
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

// Logout revokes the node key with the control plane (best-effort), then stops
// the server and removes the state directory.
//
// The control-plane logout is what actually invalidates the credential.
// Without it, any surviving copy of the state DB (a cloud backup, a disk image,
// a file read before the wipe) would remain a valid credential and the device
// would stay registered in the tailnet until key expiry. It is attempted while
// the server is still running, and is best-effort: if the control plane is
// unreachable we still tear down and wipe local state so a "logout" never
// leaves the node running or its on-disk credential intact.
func Logout(stateDir string) error {
	if strings.TrimSpace(stateDir) == "" {
		return fmt.Errorf("state dir is empty")
	}

	mu.Lock()
	s := srv
	host := lastHostname
	ctrlURL := lastControlURL
	mu.Unlock()
	if s != nil {
		revokeNodeKey(s)
	} else if ctrlURL != "" && HasState(stateDir) {
		// The caller stopped the server before logging out, so there's no live
		// client to revoke through. Briefly bring the persisted node back up to
		// expire its key at the control plane — a logout must clear the node
		// from the tailnet, not just wipe the local credential.
		revokeStoppedNode(host, ctrlURL, stateDir)
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
	var lc *local.Client
	if srv != nil {
		lc, _ = srv.LocalClient()
	}
	closeAllServePublications(lc)
	closeAllTcpFdListeners()
	closeAllHttpBindings()
	closeAllFunnelForwarders()

	// Stop the state watcher and drop cached identities together. StopWatch
	// cancels the watcher's ctx and invalidates the cache under watchMu, and
	// the watcher gates its cache mirror on that same ctx — so no in-flight
	// netmap tick can re-warm a torn-down cache. Idempotent, so it's safe even
	// when Dart already called StopWatch on its own teardown path.
	StopWatch()

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
func Start(hostname, authKey, controlURL, stateDir string, ephemeral bool) (err error) {
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
		// Best-effort revoke the current node key before wiping its state, so
		// the old identity doesn't linger registered in the tailnet until key
		// expiry. Done while the server is still up; failures are non-fatal.
		revokeNodeKey(srv)
		stopLocked()
		if err := os.RemoveAll(stateDir); err != nil {
			return fmt.Errorf("failed to clear state dir for re-auth: %w", err)
		}
	}

	os.Setenv("TS_ENABLE_RAW_DISCO", "false")

	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return fmt.Errorf("failed to create state dir: %v", err)
	}
	// MkdirAll is a no-op on an existing directory and never tightens its
	// permissions, so enforce 0700 explicitly — this dir holds the node's
	// private keys and must not be traversable by other local users. Best
	// effort: don't fail startup on platforms/filesystems without chmod.
	if err := os.Chmod(stateDir, 0700); err != nil {
		logInfo("Start: could not enforce 0700 on state dir %q: %v", stateDir, err)
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
		Ephemeral:  ephemeral,
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

	// tsnet's LocalClient reaches the LocalAPI over an in-process memory pipe,
	// yet local.Client still runs its per-request auth-token lookup on every
	// call. On darwin that lookup forks `lsof` to find the macOS GUI app's
	// "sameuserproof" credential file — which never exists in an embedded
	// process — costing ~40ms per call and taxing every LocalAPI op
	// (WhoIs/Status/Prefs/Ping) on the shared DoLocalRequest path. The
	// in-process pipe is already a trust boundary we own, so opt out of the
	// token dance once: each call drops from ~40ms to ~0.1ms. Done under mu
	// before srv is published, so no in-flight call races the write. See
	// loopback_latency_diag_test.go for the bisection.
	if lc, lcErr := newSrv.LocalClient(); lcErr == nil {
		lc.OmitAuth = true
	}

	// Commit to package state only after every allocation succeeded.
	srv = newSrv
	store = newStore
	lastHostname = hostname
	lastControlURL = controlURL
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

// revokeNodeKey best-effort expires the node key with the control plane via
// the LocalAPI Logout, bounded by a timeout. Callers invoke this while the
// server is still running and before wiping local state; failures are logged
// and swallowed so local teardown always proceeds.
func revokeNodeKey(s *tsnet.Server) {
	lc, err := s.LocalClient()
	if err != nil {
		logInfo("logout: LocalClient unavailable, skipping control-plane revoke: %v", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := lc.Logout(ctx); err != nil {
		logInfo("logout: control-plane revoke failed (continuing with local wipe): %v", err)
	}
}

// revokeStoppedNode best-effort revokes the node key when Logout is called with
// no running server. It briefly brings the persisted node back up from local
// state (reusing the existing node key, no auth key) so the LocalAPI logout can
// reach the control plane, then tears the transient server down. Failures are
// logged and swallowed; the caller wipes local state regardless.
func revokeStoppedNode(hostname, controlURL, stateDir string) {
	st, err := NewSQLiteStore(stateDir + "/state.db")
	if err != nil {
		logInfo("logout: cannot open persisted state to revoke stopped node: %v", err)
		return
	}
	s := &tsnet.Server{
		Hostname:   hostname,
		ControlURL: controlURL,
		Dir:        stateDir,
		Store:      st,
		Logf: func(format string, args ...any) {
			if atomic.LoadInt32(&LogLevel) >= 2 {
				log.Printf("TSNET: "+format, args...)
			}
		},
	}
	defer func() {
		s.Close()
		st.Close()
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// Up reconnects using the persisted node key (no auth key needed) so the
	// control plane can act on the logout; bounded by ctx so an unreachable
	// control server can't hang teardown.
	if _, err := s.Up(ctx); err != nil {
		logInfo("logout: transient bring-up to revoke stopped node failed: %v", err)
		return
	}
	revokeNodeKey(s)
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
