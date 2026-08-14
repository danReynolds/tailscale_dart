package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/tsnet"
)

// LogLevel controls local stderr logging verbosity. 0=silent, 1=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var directRuntimeToken atomic.Uint64

func nextDirectRuntimeToken() uint64 {
	// Keep package-direct callers in a disjoint token namespace from Dart's
	// positive signed-64-bit supervisor tokens.
	return directRuntimeToken.Add(1) | (uint64(1) << 63)
}

// defaultNativeCallTimeout bounds native calls whose caller supplied no
// timeout. NO native call runs on an unbounded context: each in-flight call
// pins a helper isolate, an OS thread, an offload-gate permit, and a Go
// goroutine (see lib/src/worker/native_offload.dart), and a Dart-side
// `.timeout()` abandons the future without cancelling the native work — so an
// unbounded call stuck on an unreachable peer would hold all of that until
// process exit. 30s is generous for a worst-case DERP-relayed path while still
// guaranteeing stuck calls drain. The runtime's one mandatory first-Up
// bootstrap has its own stored result and a separate 30-second maximum.
const defaultNativeCallTimeout = 30 * time.Second

type runtimeStartDependencies struct {
	adoptPersistent      func(uint64, runtimeConfig) (*nodeRuntime, error)
	configureHostNetwork func(snapshot string) error
	startServer          func(server *tsnet.Server) error
	localClient          func(server *tsnet.Server) (*local.Client, error)
	closeServer          func(server *tsnet.Server) error
}

var productionRuntimeStartDependencies = runtimeStartDependencies{
	adoptPersistent:      runtimes.adoptPersistentPreparation,
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

// LogoutResult is the event-silent lifecycle receipt returned to Dart. Started
// means a live or temporary runtime was actually detached for close. EmitStopped
// is narrower: the public node was active when logout began, so Dart should
// publish the terminal transition. NoState means upstream confirmed there is no
// logged-in profile, or the configured root was already clean; it does not mean
// the lower-level StateStore container was deleted.
type LogoutResult struct {
	Token         uint64 `json:"token"`
	Started       bool   `json:"started"`
	EmitStopped   bool   `json:"emitStopped,omitempty"`
	NoState       bool   `json:"noState"`
	CleanupFailed bool   `json:"cleanupFailed,omitempty"`
	receiptStored bool
}

// sortedPeers flattens a Status peer map into upstream's stable peer order.
func sortedPeers(status *ipnstate.Status) []*ipnstate.PeerStatus {
	peers := make([]*ipnstate.PeerStatus, 0, len(status.Peer))
	for _, peer := range status.Peer {
		peers = append(peers, peer)
	}
	ipnstate.SortPeers(peers)
	return peers
}

// closeReceipt converts a logout disposition into the retained lifecycle
// receipt shape shared by the initiating call and rescue recovery. Keep its
// field mapping in sync with the ADR's logout disposition table.
func (r LogoutResult) closeReceipt() RuntimeCloseResult {
	return RuntimeCloseResult{
		Token:         r.Token,
		Operation:     lifecycleOperationLogout,
		Matched:       true,
		Started:       r.Started,
		EmitStopped:   r.EmitStopped,
		NoState:       r.NoState,
		CleanupFailed: r.CleanupFailed,
	}
}

type runtimeLogoutDependencies struct {
	prepareIdleRuntime func(uint64, string) (uint64, error)
	revokeNodeKey      func(*nodeRuntime) error
	closeRuntime       func(uint64) (RuntimeCloseResult, error)
}

var productionRuntimeLogoutDependencies = runtimeLogoutDependencies{
	prepareIdleRuntime: func(token uint64, hostNetworkSnapshot string) (uint64, error) {
		if _, _, err := configuredStateRootSnapshot(); err != nil {
			return 0, err
		}
		preparation, err := persistentPreparationForToken(token)
		if err != nil {
			return 0, err
		}
		preparation.phaseMu.Lock()
		store := preparation.store
		ready := store != nil && preparation.custodyCompleted && !preparation.custodyActive
		preparation.phaseMu.Unlock()
		if !ready {
			return 0, fmt.Errorf("%w: idle logout requires authenticated prepared state", ErrRuntimeStale)
		}
		config, err := loadRuntimeConfig(store)
		if err != nil {
			cleanupErr := FinishPreparedPersistentState(token)
			return 0, errors.Join(
				fmt.Errorf("load persistent runtime configuration: %w", err),
				cleanupErr,
			)
		}
		_, runtimeToken, err := StartRuntimeWithToken(
			token,
			config.hostname,
			"",
			config.controlURL,
			false,
			hostNetworkSnapshot,
		)
		if err != nil {
			// An error after adoption is cleaned by the candidate's deferred
			// teardown, so the preparation is already stale. An error before
			// adoption still owns the Store+lease and must release both here.
			cleanupErr := FinishPreparedPersistentState(token)
			if errors.Is(cleanupErr, ErrRuntimeStale) {
				cleanupErr = nil
			}
			err = errors.Join(err, cleanupErr)
		}
		return runtimeToken, err
	},
	revokeNodeKey: revokeNodeKey,
	closeRuntime:  closeRuntimeForLogout,
}

// Logout follows the remote-first contract using either the active runtime or
// a temporary runtime reconstructed from persisted state.
func Logout() error {
	token := nextDirectRuntimeToken()
	if runtime := currentRuntime(); runtime != nil {
		token = runtime.token
	}
	result, err := LogoutWithToken(token, "")
	AcknowledgeLifecycleResult(result.Token)
	return err
}

// LogoutWithToken delegates profile removal to upstream Tailscale and always
// preserves the lower-level StateStore container. A failure/timeout closes the
// potentially mutated runtime and returns ErrLogoutIndeterminate.
func LogoutWithToken(requestToken uint64, hostNetworkSnapshot string) (result LogoutResult, err error) {
	result, err = logoutWithDependencies(
		requestToken,
		hostNetworkSnapshot,
		productionRuntimeLogoutDependencies,
	)
	// Cleanup can fail before beginLogout installs its deferred terminal
	// receipt, for example while unwinding a temporary runtime reconstructed
	// from persisted state. Preserve that disposition independently of where
	// the typed error originated so both the direct response and rescue receipt
	// poison the Dart supervisor consistently.
	if errors.Is(err, ErrRuntimeCleanupFailed) {
		result.CleanupFailed = true
	}
	if !result.receiptStored {
		runtimes.recordLifecycleReceipt(lifecycleReceipt{result: result.closeReceipt(), err: err})
	}
	return result, err
}

func logoutWithDependencies(requestToken uint64, hostNetworkSnapshot string, dependencies runtimeLogoutDependencies) (result LogoutResult, err error) {
	result = LogoutResult{Token: requestToken}
	if err := runtimeCleanupAdmissionError(); err != nil {
		return result, err
	}

	runtime := currentRuntime()
	publicRuntimeWasActive := runtime != nil
	if runtime != nil {
		if requestToken == 0 || runtime.token != requestToken {
			return result, fmt.Errorf("%w: logout token does not own the active runtime", ErrRuntimeStale)
		}
		result.Token = runtime.token
	} else {
		runtimeToken, err := dependencies.prepareIdleRuntime(requestToken, hostNetworkSnapshot)
		if err != nil {
			return result, err
		}
		result.Token = runtimeToken
		runtime = currentRuntime()
		if runtime == nil || runtime.token != runtimeToken {
			return result, fmt.Errorf("%w: logout runtime was not published", ErrRuntimeStale)
		}
	}

	logout, err := runtimes.beginLogout(runtime)
	if err != nil {
		return result, err
	}
	result.receiptStored = true
	var cleanupErr error
	defer func() { runtimes.finishLogout(logout, result, err, cleanupErr) }()

	logoutErr := dependencies.revokeNodeKey(runtime)
	if logoutErr != nil {
		closeResult, closeErr := dependencies.closeRuntime(runtime.token)
		result.Started = closeResult.Started
		result.EmitStopped = publicRuntimeWasActive && closeResult.Started
		result.CleanupFailed = closeErr != nil
		cleanupErr = runtimes.recordCleanupFailure(runtime.token, closeErr)
		return result, errors.Join(
			ErrLogoutIndeterminate,
			fmt.Errorf("upstream logout result is indeterminate: %w", logoutErr),
			cleanupErr,
		)
	}

	closeResult, closeErr := dependencies.closeRuntime(runtime.token)
	result.Started = closeResult.Started
	result.EmitStopped = publicRuntimeWasActive && closeResult.Started
	result.CleanupFailed = closeErr != nil
	cleanupErr = runtimes.recordCleanupFailure(runtime.token, closeErr)
	if closeErr != nil {
		return result, cleanupErr
	}
	result.NoState = true
	return result, nil
}

// Stop stops the server and closes all listeners. Public lifecycle events are
// emitted by the Dart supervisor from the token-qualified close receipt.
func Stop() {
	_, err := closeCurrentRuntime()
	if err != nil {
		logInfo("Stop: runtime cleanup failed: %v", err)
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
	alreadyActive, _, err = StartRuntimeWithToken(
		nextDirectRuntimeToken(),
		hostname,
		authKey,
		controlURL,
		ephemeral,
		"",
	)
	return alreadyActive, err
}

// StartRuntimeWithToken binds native preparation to a token created by the
// live Dart supervisor before it dispatches work to the control isolate. The
// returned token is the active runtime token; for an idempotent start it may be
// older than requestToken.
func StartRuntimeWithToken(requestToken uint64, hostname, authKey, controlURL string, ephemeral bool, hostNetworkSnapshot string) (alreadyActive bool, runtimeToken uint64, err error) {
	return startRuntimeWithTokenDeadline(
		requestToken,
		hostname,
		authKey,
		controlURL,
		ephemeral,
		hostNetworkSnapshot,
		time.Time{},
	)
}

// StartRuntimeWithBootstrapBudget is the public-Dart startup path. The budget
// is captured at native entry so Server.Start time is charged to the caller's
// original up(timeout:) deadline. Internal temporary runtimes use
// StartRuntimeWithToken and therefore never race an automatic bootstrap with
// idle logout reconstruction.
func StartRuntimeWithBootstrapBudget(requestToken uint64, hostname, authKey, controlURL string, ephemeral bool, hostNetworkSnapshot string, bootstrapBudget time.Duration) (alreadyActive bool, runtimeToken uint64, err error) {
	return startRuntimeWithTokenDeadline(
		requestToken,
		hostname,
		authKey,
		controlURL,
		ephemeral,
		hostNetworkSnapshot,
		time.Now().Add(bootstrapBudget),
	)
}

func startRuntimeWithTokenDeadline(requestToken uint64, hostname, authKey, controlURL string, ephemeral bool, hostNetworkSnapshot string, bootstrapDeadline time.Time) (alreadyActive bool, runtimeToken uint64, err error) {
	startCall, err := runtimes.beginStartCall(requestToken)
	if err != nil {
		return false, 0, err
	}
	defer runtimes.finishStartCall(requestToken, startCall)

	stateDir, err := configuredStateDir()
	if err != nil {
		return false, 0, err
	}
	return startRuntimeWithDependenciesForTokenAndDeadline(
		requestToken,
		hostname,
		authKey,
		controlURL,
		stateDir,
		ephemeral,
		hostNetworkSnapshot,
		productionRuntimeStartDependencies,
		bootstrapDeadline,
	)
}

func startRuntimeWithDependencies(hostname, authKey, controlURL, stateDir string, ephemeral bool, hostNetworkSnapshot string, dependencies runtimeStartDependencies) (alreadyActive bool, err error) {
	alreadyActive, _, err = startRuntimeWithDependenciesForTokenAndDeadline(
		nextDirectRuntimeToken(),
		hostname,
		authKey,
		controlURL,
		stateDir,
		ephemeral,
		hostNetworkSnapshot,
		dependencies,
		time.Time{},
	)
	return alreadyActive, err
}

func startRuntimeWithDependenciesForTokenAndDeadline(requestToken uint64, hostname, authKey, controlURL, stateDir string, ephemeral bool, hostNetworkSnapshot string, dependencies runtimeStartDependencies, bootstrapDeadline time.Time) (alreadyActive bool, runtimeToken uint64, err error) {
	config := runtimeConfig{
		hostname:   hostname,
		controlURL: controlURL,
		ephemeral:  ephemeral,
	}
	refreshed, err := runtimes.refreshActiveRuntime(requestToken, config, func() error {
		return applyHostNetworkSnapshot(hostNetworkSnapshot, dependencies)
	})
	if err != nil {
		return false, 0, err
	}
	if refreshed != nil {
		if !bootstrapDeadline.IsZero() && refreshed.publication != nil {
			refreshed.publication.beginInitiatingUp(bootstrapDeadline)
		}
		return true, refreshed.token, nil
	}
	var candidate, active *nodeRuntime
	if ephemeral {
		candidate, active, err = runtimes.reserve(requestToken, config)
	} else {
		adopt := dependencies.adoptPersistent
		if adopt == nil {
			adopt = runtimes.adoptPersistentPreparation
		}
		candidate, err = adopt(requestToken, config)
	}
	if err != nil {
		return false, 0, err
	}
	if active != nil {
		// reserve rechecked controller state after the first probe and observed a
		// runtime published by another direct caller. Re-enter the same guarded
		// refresh path instead of mutating host globals outside admission.
		refreshed, refreshErr := runtimes.refreshActiveRuntime(requestToken, config, func() error {
			return applyHostNetworkSnapshot(hostNetworkSnapshot, dependencies)
		})
		if refreshErr != nil {
			return false, 0, refreshErr
		}
		if refreshed == nil {
			return false, 0, fmt.Errorf("%w: active runtime changed during refresh", ErrRuntimeStale)
		}
		if !bootstrapDeadline.IsZero() && refreshed.publication != nil {
			refreshed.publication.beginInitiatingUp(bootstrapDeadline)
		}
		return true, refreshed.token, nil
	}

	serverStarted := false
	defer func() {
		if err == nil {
			return
		}
		var cleanupErr error
		if serverStarted {
			cleanupErr = candidate.close()
		} else {
			// Server.Start owns and unwinds its partial initialization on error.
			// Calling Server.Close concurrently or after that error violates the
			// upstream lifecycle contract; only caller-owned resources close here.
			cleanupErr = candidate.closeUnstarted()
		}
		if errors.Is(err, ErrRuntimeCleanupFailed) {
			cleanupErr = errors.Join(cleanupErr, err)
		}
		cleanupErr = runtimes.release(candidate, cleanupErr)
		err = errors.Join(err, cleanupErr)
	}()

	if ephemeral {
		if err := prepareEphemeralRuntime(candidate, authKey); err != nil {
			return false, 0, err
		}
	}

	setRawDiscoCompatibility()
	if runtimes.isAbandoned(candidate) {
		return false, 0, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, candidate.token)
	}
	if err := runtimes.applyHostNetworkSnapshot(hostNetworkSnapshot, dependencies); err != nil {
		return false, 0, err
	}
	if runtimes.isAbandoned(candidate) {
		return false, 0, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, candidate.token)
	}

	runtimeDir := candidate.scratchDirectory()
	if !ephemeral {
		runtimeDir = filepath.Join(stateDir, "tsnet")
		if err := ensurePrivateOwnedDirectory(runtimeDir); err != nil {
			return false, 0, fmt.Errorf("prepare runtime dir: %w", err)
		}
	}
	logDir := runtimeDir

	if !ephemeral {
		// A new Server.Start may mutate the profile before it returns an error.
		// Invalidate the prior proven tuple first so idle logout can never
		// reconstruct that possibly-mutated state under stale configuration.
		if err := clearRuntimeConfig(candidate.store); err != nil {
			return false, 0, fmt.Errorf("invalidate runtime configuration: %w", err)
		}
	}
	candidate.closeServer = dependencies.closeServer
	if runtimes.isAbandoned(candidate) {
		return false, 0, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, candidate.token)
	}

	nativeLogf := func(format string, args ...any) {
		logInfo(format, args...)
	}
	newSrv := &tsnet.Server{
		Hostname:   hostname,
		AuthKey:    authKey,
		ControlURL: controlURL,
		Dir:        runtimeDir,
		Store:      candidate.store,
		Ephemeral:  ephemeral,
		Logf:       nativeLogf,
		UserLogf:   nativeLogf,
	}
	candidate.server = newSrv

	// Android apps do not have the desktop/server filesystem locations that
	// Tailscale's log policy probes by default. Scope this process-global input
	// to Server.Start and restore the embedding application's prior value.
	serverStarted, startErr := startServerWithScopedLogs(
		logDir,
		func() error { return dependencies.startServer(newSrv) },
	)
	// Upstream consumes AuthKey during Start. Do not retain that credential on
	// the long-lived Server after either a successful or failed start.
	newSrv.AuthKey = ""
	if startErr != nil {
		return false, 0, fmt.Errorf("failed to start tsnet: %w", startErr)
	}
	if !ephemeral {
		// Server.Start is the proof boundary for the immutable tuple used by
		// event-silent idle logout reconstruction.
		if err := saveRuntimeConfig(candidate.store, config); err != nil {
			return false, 0, fmt.Errorf("persist proven runtime configuration: %w", err)
		}
	}
	if runtimes.isAbandoned(candidate) {
		return false, 0, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, candidate.token)
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
		return false, 0, fmt.Errorf("get local client after start: %w", err)
	}
	lc.OmitAuth = true
	candidate.localClient = lc
	candidate.publication = newPublicationManager(candidate, lc)
	if !bootstrapDeadline.IsZero() {
		candidate.publication.beginInitiatingUp(bootstrapDeadline)
	}

	// Commit to controller state only after every allocation succeeded. No
	// per-subsystem re-arming is needed: ops gate on the node epoch (bumped by
	// closeCurrentRuntime), and a gate acquired after this point is current by
	// construction.
	if err := runtimes.commit(candidate); err != nil {
		return false, 0, err
	}
	return false, candidate.token, nil
}

// MarkRuntimeUpSettled linearizes a completed Dart up Future with the exact
// runtime's future first-Running observation. Stale tokens are harmless.
func MarkRuntimeUpSettled(token uint64) {
	runtime := currentRuntime()
	if runtime == nil || runtime.token != token || runtime.publication == nil {
		return
	}
	runtime.publication.markInitiatingUpSettled()
}

var ErrEphemeralAuthKeyRequired = errors.New("ephemeral startup requires an auth key")

func prepareEphemeralRuntime(candidate *nodeRuntime, authKey string) error {
	if candidate == nil {
		return fmt.Errorf("ephemeral runtime candidate is nil")
	}
	if authKey == "" {
		return ErrEphemeralAuthKeyRequired
	}
	baseRoot, expectedRoot, err := configuredStateRootSnapshot()
	if err != nil {
		return err
	}
	lease, err := acquireStateLease(baseRoot, withExpectedStateLeaseRoot(expectedRoot))
	if err != nil {
		return err
	}
	candidate.stateLease = lease
	if err := validateEphemeralPersistentOccupancy(baseRoot); err != nil {
		return err
	}
	if _, err := sweepStaleEphemeralStateScratch(); err != nil {
		logInfo("ephemeral scratch sweep: %v", err)
	}
	scratch, err := createEphemeralStateScratch()
	if err != nil {
		return err
	}
	candidate.scratch = scratch
	store, err := mem.New(func(string, ...any) {}, "")
	if err != nil {
		return fmt.Errorf("create ephemeral in-memory StateStore: %w", err)
	}
	candidate.store = store
	return nil
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
	if runtime.publication != nil {
		status.BackendState = runtime.publication.maskRunningState(status.BackendState)
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

	peers := sortedPeers(status)

	jsonBytes, err := json.Marshal(peers)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

// revokeNodeKey invokes upstream logout while the runtime remains current.
// Any failure is indeterminate and must be handled by closing while retaining
// local recovery evidence.
func revokeNodeKey(runtime *nodeRuntime) error {
	if runtime == nil || runtime.localClient == nil {
		return fmt.Errorf("LocalClient unavailable")
	}
	ctx, cancel := context.WithTimeout(runtime.ctx, 10*time.Second)
	defer cancel()
	err := runtime.localClient.Logout(ctx)
	return runtime.resultError(err)
}

func jsonError(err error) string {
	m := map[string]string{"error": err.Error()}
	b, _ := json.Marshal(m)
	return string(b)
}

func logInfo(format string, args ...any) {
	if atomic.LoadInt32(&LogLevel) >= 1 {
		log.Printf("TSNET: "+format, args...)
	}
}
