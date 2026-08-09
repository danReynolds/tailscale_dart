package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
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

// defaultNativeCallTimeout bounds native calls whose caller supplied no
// timeout. NO native call runs on an unbounded context: each in-flight call
// pins a helper isolate, an OS thread, an offload-gate permit, and a Go
// goroutine (see lib/src/worker/native_offload.dart), and a Dart-side
// `.timeout()` abandons the future without cancelling the native work — so an
// unbounded call stuck on an unreachable peer would hold all of that until
// process exit. 30s is generous for a worst-case DERP-relayed path while still
// guaranteeing stuck calls drain. (ListenFunnel's internal Up remains
// unbounded inside tsnet; its outer Up is bounded by funnelUpTimeout.)
const defaultNativeCallTimeout = 30 * time.Second

type runtimeStartDependencies struct {
	openStore            func(path string) (ipn.StateStore, io.Closer, error)
	configureHostNetwork func(snapshot string) error
	startServer          func(server *tsnet.Server) error
	localClient          func(server *tsnet.Server) (*local.Client, error)
	closeServer          func(server *tsnet.Server) error
}

var productionRuntimeStartDependencies = runtimeStartDependencies{
	openStore: func(path string) (ipn.StateStore, io.Closer, error) {
		store, err := NewSQLiteStore(path)
		return store, store, err
	},
	configureHostNetwork: ConfigureHostNetworkSnapshot,
	startServer:          func(server *tsnet.Server) error { return server.Start() },
	localClient: func(server *tsnet.Server) (*local.Client, error) {
		return server.LocalClient()
	},
	closeServer: func(server *tsnet.Server) error { return server.Close() },
}

// boundedCallCtx returns a context bounded by [timeout] when positive, else by
// defaultNativeCallTimeout. Callers must defer cancel.
func boundedCallCtx(timeout time.Duration) (context.Context, context.CancelFunc) {
	return boundedCallCtxFrom(context.Background(), timeout)
}

func boundedCallCtxFrom(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout <= 0 {
		timeout = defaultNativeCallTimeout
	}
	return context.WithTimeout(parent, timeout)
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
func Logout() error {
	stateDir, err := configuredStateDir()
	if err != nil {
		return err
	}

	runtime := currentRuntime()
	if runtime != nil {
		revokeNodeKey(runtime.localClient)
	}

	wasRunning, closeErr := closeCurrentRuntime()
	if wasRunning {
		publishState("Stopped")
	}
	removeErr := os.RemoveAll(stateDir)
	if removeErr != nil {
		closeErr = errors.Join(closeErr, fmt.Errorf("failed to remove state dir: %w", removeErr))
	}
	if closeErr != nil {
		return closeErr
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
	wasRunning, err := closeCurrentRuntime()
	if err != nil {
		logInfo("Stop: runtime cleanup failed: %v", err)
	}
	if wasRunning {
		publishState("Stopped")
	}
}

// Start initializes the Tailscale node.
func Start(hostname, authKey, controlURL string, ephemeral bool) error {
	_, err := StartRuntime(hostname, authKey, controlURL, ephemeral)
	return err
}

// StartRuntime constructs and atomically publishes one runtime. alreadyActive
// is true only for an idempotent active-runtime call with the same immutable
// configuration; authKey is enrollment input and never forces replacement.
func StartRuntime(hostname, authKey, controlURL string, ephemeral bool) (alreadyActive bool, err error) {
	return StartRuntimeWithHostNetwork(hostname, authKey, controlURL, ephemeral, "")
}

// StartRuntimeWithHostNetwork applies the Android host-network snapshot only
// after reserving a fresh candidate. Active no-ops and configuration mismatches
// therefore cannot mutate the current runtime before their config is checked.
func StartRuntimeWithHostNetwork(hostname, authKey, controlURL string, ephemeral bool, hostNetworkSnapshot string) (alreadyActive bool, err error) {
	stateDir, err := configuredStateDir()
	if err != nil {
		return false, err
	}
	return startRuntimeWithDependencies(
		hostname,
		authKey,
		controlURL,
		stateDir,
		ephemeral,
		hostNetworkSnapshot,
		productionRuntimeStartDependencies,
	)
}

func startRuntimeWithDependencies(hostname, authKey, controlURL, stateDir string, ephemeral bool, hostNetworkSnapshot string, dependencies runtimeStartDependencies) (alreadyActive bool, err error) {
	config := runtimeConfig{
		hostname:   hostname,
		controlURL: controlURL,
		ephemeral:  ephemeral,
	}
	candidate, active, err := runtimes.reserve(config)
	if err != nil {
		return false, err
	}
	if active != nil {
		// Repeated same-config up() calls are identity no-ops, but Android's
		// host interface snapshot is live process input and must still refresh.
		// reserve validated the immutable runtime tuple before this mutation, so
		// a configuration mismatch cannot alter the active runtime's snapshot.
		if err := applyHostNetworkSnapshot(hostNetworkSnapshot, dependencies); err != nil {
			return false, err
		}
		return true, nil
	}

	serverStarted := false
	defer func() {
		if err == nil {
			return
		}
		if serverStarted {
			err = errors.Join(err, candidate.close())
		} else {
			// Server.Start owns and unwinds its partial initialization on error.
			// Calling Server.Close concurrently or after that error violates the
			// upstream lifecycle contract; only caller-owned resources close here.
			candidate.cancel()
			if candidate.storeCloser != nil {
				err = errors.Join(err, candidate.storeCloser.Close())
			}
		}
		runtimes.release(candidate)
	}()

	if err := setRawDiscoCompatibility(); err != nil {
		return false, err
	}
	if err := applyHostNetworkSnapshot(hostNetworkSnapshot, dependencies); err != nil {
		return false, err
	}

	if err := ensurePrivateDirectory(stateDir); err != nil {
		return false, fmt.Errorf("prepare state dir: %w", err)
	}
	logDir := filepath.Join(stateDir, "logs")
	if err := ensurePrivateDirectory(logDir); err != nil {
		return false, fmt.Errorf("prepare log dir: %w", err)
	}

	statePath := filepath.Join(stateDir, "state.db")
	newStore, newStoreCloser, err := dependencies.openStore(statePath)
	if err != nil {
		return false, fmt.Errorf("failed to create sqlite store: %w", err)
	}
	candidate.store = newStore
	candidate.storeCloser = newStoreCloser
	candidate.closeServer = dependencies.closeServer

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
	candidate.server = newSrv

	// Android apps do not have the desktop/server filesystem locations that
	// Tailscale's log policy probes by default. Scope this process-global input
	// to Server.Start and restore the embedding application's prior value.
	serverStarted, startErr := startServerWithScopedLogs(
		logDir,
		func() error { return dependencies.startServer(newSrv) },
	)
	if startErr != nil {
		return false, fmt.Errorf("failed to start tsnet: %w", startErr)
	}

	// tsnet's LocalClient reaches the LocalAPI over an in-process memory pipe,
	// yet local.Client still runs its per-request auth-token lookup on every
	// call. On darwin that lookup forks `lsof` to find the macOS GUI app's
	// "sameuserproof" credential file — which never exists in an embedded
	// process — costing ~40ms per call and taxing every LocalAPI op
	// (WhoIs/Status/Prefs/Ping) on the shared DoLocalRequest path. The
	// in-process pipe is already a trust boundary we own, so opt out of the
	// token dance once: each call drops from ~40ms to ~0.1ms. Done before the
	// runtime is published, so no in-flight call races the write. See
	// loopback_latency_diag_test.go for the bisection.
	lc, err := dependencies.localClient(newSrv)
	if err != nil {
		return false, fmt.Errorf("get local client after start: %w", err)
	}
	lc.OmitAuth = true
	candidate.localClient = lc

	// Commit to controller state only after every allocation succeeded. No
	// per-subsystem re-arming is needed: ops gate on the node epoch (bumped by
	// closeCurrentRuntime), and a gate acquired after this point is current by
	// construction.
	if err := runtimes.commit(candidate); err != nil {
		return false, err
	}
	return false, nil
}

func applyHostNetworkSnapshot(snapshot string, dependencies runtimeStartDependencies) error {
	if snapshot == "" {
		return nil
	}
	configure := dependencies.configureHostNetwork
	if configure == nil {
		configure = ConfigureHostNetworkSnapshot
	}
	if err := configure(snapshot); err != nil {
		return fmt.Errorf("configure host network snapshot: %w", err)
	}
	return nil
}

func startServerWithScopedLogs(logDir string, start func() error) (started bool, err error) {
	previousLogDir, hadLogDir := os.LookupEnv("TS_LOGS_DIR")
	if err := os.Setenv("TS_LOGS_DIR", logDir); err != nil {
		return false, fmt.Errorf("configure TS_LOGS_DIR: %w", err)
	}

	startErr := start()
	started = startErr == nil
	var restoreErr error
	if hadLogDir {
		restoreErr = os.Setenv("TS_LOGS_DIR", previousLogDir)
	} else {
		restoreErr = os.Unsetenv("TS_LOGS_DIR")
	}
	if restoreErr != nil {
		restoreErr = fmt.Errorf("restore TS_LOGS_DIR: %w", restoreErr)
	}
	return started, errors.Join(startErr, restoreErr)
}

// DuneStatus returns the local-node status JSON from the LocalAPI.
func DuneStatus() string {
	runtime := currentRuntime()
	if runtime == nil {
		return "{}"
	}
	lc := runtime.localClient
	ctx, cancel := boundedCallCtxFrom(runtime.ctx, 0)
	defer cancel()
	status, err := lc.StatusWithoutPeers(ctx)
	err = runtime.resultError(err)
	if err != nil {
		return localAPIError(err)
	}
	jsonBytes, err := json.Marshal(status)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

// DunePeers returns the current peer list as JSON.
func DunePeers() string {
	runtime := currentRuntime()
	if runtime == nil {
		return "[]"
	}
	lc := runtime.localClient
	ctx, cancel := boundedCallCtxFrom(runtime.ctx, 0)
	defer cancel()
	status, err := lc.Status(ctx)
	err = runtime.resultError(err)
	if err != nil {
		return localAPIError(err)
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
func revokeNodeKey(lc *local.Client) {
	if lc == nil {
		logInfo("logout: LocalClient unavailable, skipping control-plane revoke")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := lc.Logout(ctx); err != nil {
		logInfo("logout: control-plane revoke failed (continuing with local wipe): %v", err)
	}
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
