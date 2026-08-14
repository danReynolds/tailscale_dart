package tailscale

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"
	"tailscale.com/util/mak"
)

// ErrLifecycleBusy means a node is being prepared or drained. Callers must
// wait for that lifecycle transition to finish instead of starting a second
// tsnet.Server against the same process-owned state.
var ErrLifecycleBusy = errors.New("tailscale lifecycle busy")

// ErrRuntimeCleanupFailed means a runtime-owned Server, Store, or persisted
// state reset did not finish cleanly. Native lifecycle admission remains
// closed for the rest of the process so a replacement cannot overlap unknown
// resources or consume partially removed state.
var ErrRuntimeCleanupFailed = errors.New("tailscale runtime cleanup failed")

// ErrConfigurationMismatch means an immutable process or active-runtime
// setting differs from the value that already owns this process.
var ErrConfigurationMismatch = errors.New("tailscale configuration mismatch")

// ErrRuntimeStale means an operation captured a runtime generation that has
// since been detached or canceled.
var ErrRuntimeStale = errors.New("tailscale runtime stopped or stale")

// ErrStartupAbandoned means the supervisor quarantined a preparation token
// while native construction was still in flight. A successful late Start is
// closed instead of becoming current.
var ErrStartupAbandoned = errors.New("tailscale startup abandoned")

// ErrLogoutIndeterminate means upstream logout may have changed remote or
// in-memory state, but its result was not confirmed. Local state is retained
// and the affected runtime is closed so a later fresh start can reconcile.
var ErrLogoutIndeterminate = errors.New("tailscale logout indeterminate")

const rawDiscoEnv = "TS_ENABLE_RAW_DISCO"

type runtimeConfig struct {
	hostname   string
	controlURL string
	ephemeral  bool
}

// nodeRuntime owns everything whose lifetime is exactly one tsnet.Server
// generation. Its publication manager is the sole Serve/Funnel authority for
// that generation; its transport pool, fd registries, and state watcher are
// likewise runtime-owned and have their teardown centralized in close.
type nodeRuntime struct {
	generation uint64
	token      uint64
	config     runtimeConfig

	ctx    context.Context
	cancel context.CancelFunc

	server      *tsnet.Server
	localClient *local.Client
	publication *publicationManager
	store       ipn.StateStore
	storeCloser io.Closer
	stateLease  *stateLease
	scratch     *ephemeralStateScratch
	closeServer func(*tsnet.Server) error

	preparationDone     chan struct{}
	preparationDoneOnce sync.Once
	preparationErr      error
	closeOnce           sync.Once
	closeErr            error
	abandoned           bool // guarded by runtimeController.mu

	httpMu              sync.Mutex
	httpTransport       *http.Transport
	httpTransportClosed bool

	fd fdResources
	// identity is the watcher-maintained accept hot-path index for this exact
	// server generation. A replacement runtime starts cold by construction.
	identity identityIndex

	watchMu sync.Mutex
	watch   *watcherRun
}

// tailnetTransport returns this runtime's one outbound HTTP transport (an
// HTTP connection pool + TLS session cache), building it on first use. The
// pool is a SECURITY boundary, not just hygiene: a pooled connection carries
// the tailnet identity that was live when it was dialed and must never serve
// a different identity. Runtime ownership makes that structural — a
// replacement identity is a new runtime with an empty slot, and close drains
// this one. A request that raced close gets a one-off transport without
// touching the slot — reported via oneOff=true so the caller closes its idle
// connections after use — because repopulating a closed slot would retain the
// dead server's whole netstack graph behind the teardown sweep. Cross-host
// isolation is inherent to http.Transport (its pool is keyed by host:port).
func (r *nodeRuntime) tailnetTransport(build func() *http.Transport) (transport *http.Transport, oneOff bool) {
	r.httpMu.Lock()
	defer r.httpMu.Unlock()
	if r.httpTransportClosed {
		return build(), true
	}
	if r.httpTransport == nil {
		r.httpTransport = build()
	}
	return r.httpTransport, false
}

// closeTailnetTransport drops the runtime's transport and closes its idle
// connections. Called from close so no pooled connection outlives the
// node/identity; later stragglers receive one-off transports.
func (r *nodeRuntime) closeTailnetTransport() {
	r.httpMu.Lock()
	defer r.httpMu.Unlock()
	r.httpTransportClosed = true
	if r.httpTransport != nil {
		r.httpTransport.CloseIdleConnections()
		r.httpTransport = nil
	}
}

func newNodeRuntime(generation, token uint64, config runtimeConfig) *nodeRuntime {
	ctx, cancel := context.WithCancel(context.Background())
	return &nodeRuntime{
		generation:      generation,
		token:           token,
		config:          config,
		ctx:             ctx,
		cancel:          cancel,
		preparationDone: make(chan struct{}),
	}
}

func (r *nodeRuntime) finishPreparation() {
	r.finishPreparationWithError(nil)
}

func (r *nodeRuntime) finishPreparationWithError(err error) {
	r.preparationDoneOnce.Do(func() {
		r.preparationErr = err
		close(r.preparationDone)
	})
}

func (r *nodeRuntime) validateCurrent() error {
	if r == nil || r.ctx.Err() != nil || nodeEpoch.Load() != r.generation {
		return ErrRuntimeStale
	}
	return nil
}

func (r *nodeRuntime) resultError(err error) error {
	if staleErr := r.validateCurrent(); staleErr != nil {
		return staleErr
	}
	return err
}

func (r *nodeRuntime) scratchDirectory() string {
	if r == nil || r.scratch == nil {
		return ""
	}
	return r.scratch.directory()
}

// close is the sole post-Start teardown path. The epoch is bumped and the
// runtime detached by runtimeController before this method runs, so slow
// registry cleanup and Server.Close happen without the controller lock held.
// The Server is always closed before its caller-owned StateStore.
func (r *nodeRuntime) close() error {
	return r.closeOwnedResources(true, false)
}

func (r *nodeRuntime) closeForPublicationBootstrapFailure() error {
	return r.closeOwnedResources(true, true)
}

// closeUnstarted releases caller-owned resources after Server.Start returned
// an error. Upstream owns unwinding its own partial start and must not receive
// a competing Server.Close call.
func (r *nodeRuntime) closeUnstarted() error {
	return r.closeOwnedResources(false, false)
}

func (r *nodeRuntime) closeOwnedResources(closeStartedServer, preserveBootstrapFailure bool) error {
	if r == nil {
		return nil
	}
	r.closeOnce.Do(func() {
		r.cancel()
		r.stopWatch()

		// Publication cleanup is best-effort and bounded. Do not let a stale
		// ServeConfig cleanup failure strand Server/Store/lease ownership: the
		// next generation's mandatory bootstrap is the final stale-config gate.
		if r.publication != nil {
			r.publication.shutdownBootstrap(preserveBootstrapFailure)
			_ = r.publication.close()
		}
		r.fd.closeAll()
		r.closeTailnetTransport()

		if closeStartedServer && r.server != nil {
			closeServer := r.closeServer
			if closeServer == nil {
				closeServer = func(server *tsnet.Server) error { return server.Close() }
			}
			if err := closeServer(r.server); err != nil && !errors.Is(err, net.ErrClosed) {
				r.closeErr = errors.Join(r.closeErr, fmt.Errorf("close tsnet server: %w", err))
			}
		}
		if r.storeCloser != nil {
			if err := r.storeCloser.Close(); err != nil {
				r.closeErr = errors.Join(r.closeErr, fmt.Errorf("close state store: %w", err))
			}
		}
		if r.stateLease != nil {
			if err := r.stateLease.Release(); err != nil {
				r.closeErr = errors.Join(r.closeErr, fmt.Errorf("release state lease: %w", err))
			}
		}
		if r.scratch != nil {
			if err := r.scratch.Close(); err != nil {
				r.closeErr = errors.Join(r.closeErr, fmt.Errorf("remove ephemeral state scratch: %w", err))
			}
		}
	})
	return r.closeErr
}

type drainingRuntime struct {
	runtime          *nodeRuntime
	done             chan struct{}
	err              error
	receiptOperation string
}

// logoutOperation keeps lifecycle admission closed after the matching runtime
// is detached. Its done channel is closed only after the caller has completed
// upstream logout, runtime close, and the final retained-StateStore
// disposition.
type logoutOperation struct {
	token      uint64
	done       chan struct{}
	cleanupErr error
}

type preparationOutcome struct {
	err error
}

// runtimeStartCall covers the narrow interval between a Dart worker entering
// StartRuntimeWithToken and native lifecycle admission becoming observable as
// a preparation, candidate, or runtime. Quarantine can wait on this receipt
// instead of retaining an unbounded pre-admission tombstone.
type runtimeStartCall struct {
	done chan struct{}
}

const (
	lifecycleOperationDown   = "down"
	lifecycleOperationLogout = "logout"
)

type lifecycleReceipt struct {
	result RuntimeCloseResult
	err    error
}

type runtimeCleanupFailure struct {
	token uint64
	err   error
}

// runtimeController is the single owner of candidate/current/draining runtime
// state and immutable package configuration.
type runtimeController struct {
	mu            sync.Mutex
	configureMu   sync.Mutex
	hostNetworkMu sync.Mutex

	candidate             *nodeRuntime
	current               *nodeRuntime
	draining              *drainingRuntime
	logout                *logoutOperation
	reset                 *localResetOperation
	persistentPreparation *persistentPreparation
	startCalls            map[uint64]*runtimeStartCall
	abandonedTokens       map[uint64]struct{}
	completedPreparations map[uint64]preparationOutcome
	completedLifecycle    map[uint64]lifecycleReceipt
	cleanupFailure        *runtimeCleanupFailure

	configured      bool
	stateRoot       string
	stateRootInfo   os.FileInfo
	keybayNamespace string
	logLevel        int32
	noLogsNoSupport bool
	scratchParent   string
}

var runtimes runtimeController

func (c *runtimeController) beginStartCall(token uint64) (*runtimeStartCall, error) {
	if token == 0 {
		return nil, fmt.Errorf("runtime preparation token must be non-zero")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.startCalls[token] != nil {
		return nil, fmt.Errorf("%w: start call for token %d is already active", ErrLifecycleBusy, token)
	}
	call := &runtimeStartCall{done: make(chan struct{})}
	mak.Set(&c.startCalls, token, call)
	return call, nil
}

func (c *runtimeController) finishStartCall(token uint64, call *runtimeStartCall) {
	if call == nil {
		return
	}
	c.mu.Lock()
	if c.startCalls[token] == call {
		delete(c.startCalls, token)
		// Once the one token-qualified entry call has returned, no native work
		// from that dispatch can cross admission later. Its tombstone is safe to
		// retire even when it rejected before creating a candidate.
		delete(c.abandonedTokens, token)
		close(call.done)
	}
	c.mu.Unlock()
}

// RetireAbandonedRuntimeToken acknowledges that the originating Dart Future
// or worker can no longer enter native code. If the entry call is already
// active, its defer owns retirement; otherwise the unmatched pre-dispatch
// tombstone can be removed now.
func RetireAbandonedRuntimeToken(token uint64) {
	if token == 0 {
		return
	}
	runtimes.mu.Lock()
	if runtimes.startCalls[token] == nil {
		delete(runtimes.abandonedTokens, token)
	}
	runtimes.mu.Unlock()
}

// SetEphemeralScratchParent supplies the host platform's writable temporary
// directory for ephemeral scratch. Android app processes cannot write Go's
// os.TempDir() fallback (/data/local/tmp is shell-writable only), while the
// embedding Dart runtime knows the app's real cache/temporary location, so
// Dart supplies it immediately after Configure. Empty or repeated values are
// ignored: the parent is environmental, set once, and deliberately outside
// the frozen configuration identity tuple.
func SetEphemeralScratchParent(parent string) {
	trimmed := strings.TrimSpace(parent)
	if trimmed == "" {
		return
	}
	runtimes.configureMu.Lock()
	defer runtimes.configureMu.Unlock()
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	if runtimes.scratchParent == "" {
		runtimes.scratchParent = filepath.Clean(trimmed)
	}
}

func configuredEphemeralScratchParent() string {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	return runtimes.scratchParent
}

// Configure freezes process-wide initialization identity. os.SameFile supplies
// native path/inode identity, so lexical and symlink aliases cannot create two
// owners for the same state root. keybayNamespace is compared exactly so Dart
// isolates cannot bind one native root to different secure-storage containers.
// The logging-upload choice is likewise process-wide because upstream's
// no-logs switch is deliberately irreversible for the process lifetime.
func Configure(stateRoot, keybayNamespace string, logLevel, noLogsNoSupport int32) (string, error) {
	runtimes.configureMu.Lock()
	defer runtimes.configureMu.Unlock()

	if strings.TrimSpace(stateRoot) == "" {
		return "", fmt.Errorf("state directory is empty")
	}
	if strings.TrimSpace(keybayNamespace) == "" {
		return "", fmt.Errorf("Keybay namespace is empty")
	}
	if logLevel < 0 || logLevel > 1 {
		return "", fmt.Errorf("invalid log level %d", logLevel)
	}
	if noLogsNoSupport != 0 && noLogsNoSupport != 1 {
		return "", fmt.Errorf("invalid no-logs-no-support value %d", noLogsNoSupport)
	}
	disableLogUploads := noLogsNoSupport == 1 || envknob.NoLogsNoSupport()

	abs, err := filepath.Abs(stateRoot)
	if err != nil {
		return "", fmt.Errorf("resolve state directory: %w", err)
	}
	abs = filepath.Clean(abs)

	runtimes.mu.Lock()
	alreadyConfigured := runtimes.configured
	configuredRoot := runtimes.stateRoot
	configuredRootInfo := runtimes.stateRootInfo
	configuredKeybayNamespace := runtimes.keybayNamespace
	configuredLogLevel := runtimes.logLevel
	configuredNoLogsNoSupport := runtimes.noLogsNoSupport
	runtimes.mu.Unlock()
	if alreadyConfigured {
		if configuredLogLevel != logLevel || configuredNoLogsNoSupport != disableLogUploads || configuredKeybayNamespace != keybayNamespace {
			return "", fmt.Errorf("%w: Tailscale.init already owns a different state root, Keybay namespace, or logging policy", ErrConfigurationMismatch)
		}
		resolved, err := filepath.EvalSymlinks(abs)
		if err != nil {
			return "", fmt.Errorf("%w: configured state root does not match: %v", ErrConfigurationMismatch, err)
		}
		resolved, err = filepath.Abs(resolved)
		if err != nil {
			return "", fmt.Errorf("resolve canonical state directory: %w", err)
		}
		info, err := os.Stat(resolved)
		if err != nil {
			return "", fmt.Errorf("%w: configured state root does not match: %v", ErrConfigurationMismatch, err)
		}
		if configuredRootInfo == nil || !os.SameFile(configuredRootInfo, info) {
			return "", fmt.Errorf("%w: Tailscale.init already owns a different state root, Keybay namespace, or logging policy", ErrConfigurationMismatch)
		}
		if err := ensurePrivateDirectory(resolved); err != nil {
			return "", fmt.Errorf("secure state directory: %w", err)
		}
		return configuredRoot, nil
	}

	if err := ensurePrivateDirectory(abs); err != nil {
		return "", fmt.Errorf("prepare state directory: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("resolve state directory symlinks: %w", err)
	}
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return "", fmt.Errorf("resolve canonical state directory: %w", err)
	}
	if err := ensurePrivateDirectory(resolved); err != nil {
		return "", fmt.Errorf("secure state directory: %w", err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("stat state directory: %w", err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("state path is not a directory")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("state directory permissions are %04o, want 0700", info.Mode().Perm())
	}

	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	setRawDiscoCompatibility()
	if disableLogUploads {
		// Match upstream's own DisableLogTail handling: the environment knob
		// advertises the support/telemetry choice to the control client, while
		// the process kill switch prevents tsnet's logger from buffering or
		// uploading entries. Both must happen before the first Server.Start.
		logtail.Disable()
		envknob.SetNoLogsNoSupport()
	}
	runtimes.configured = true
	runtimes.stateRoot = resolved
	runtimes.stateRootInfo = info
	runtimes.keybayNamespace = keybayNamespace
	runtimes.logLevel = logLevel
	runtimes.noLogsNoSupport = disableLogUploads
	atomic.StoreInt32(&LogLevel, logLevel)
	return resolved, nil
}

const ownedStateSubdirectory = "tailscale"

// configuredStateRoot returns the canonical app-owned coordination directory.
// Its inode is revalidated so deleting/replacing the configured directory
// cannot silently redirect credentials or the persistent-state lease.
func configuredStateRootSnapshot() (string, os.FileInfo, error) {
	runtimes.mu.Lock()
	configured := runtimes.configured
	root := runtimes.stateRoot
	rootInfo := runtimes.stateRootInfo
	runtimes.mu.Unlock()
	if !configured || rootInfo == nil {
		return "", nil, fmt.Errorf("%w: call Tailscale.init before using the native runtime", ErrConfigurationMismatch)
	}

	info, err := os.Stat(root)
	if err != nil {
		return "", nil, fmt.Errorf("%w: configured state root is unavailable: %v", ErrConfigurationMismatch, err)
	}
	if !os.SameFile(rootInfo, info) {
		return "", nil, fmt.Errorf("%w: configured state root was replaced", ErrConfigurationMismatch)
	}
	return root, rootInfo, nil
}

func configuredStateRoot() (string, error) {
	root, _, err := configuredStateRootSnapshot()
	return root, err
}

// configuredStateDir returns the package-owned Tailscale subtree selected by
// Configure. The external lock and reset marker deliberately live beside it.
func configuredStateDir() (string, error) {
	root, err := configuredStateRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, ownedStateSubdirectory), nil
}

func ensurePrivateDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("path is not a directory")
	}
	if got := info.Mode().Perm(); got != 0o700 {
		return fmt.Errorf("permissions are %04o, want 0700", got)
	}
	return nil
}

// ensurePrivateOwnedDirectory creates or secures one package-owned directory
// without following a symbolic link at that path. The configured state root
// may itself be supplied through a symlink alias and is canonicalized by
// Configure; descendants such as tailscale/ and tailscale/logs are package
// storage boundaries and must remain real, current-user-owned directories.
// It shares the encrypted store's handle-verified TOCTOU choreography so the
// securing discipline exists exactly once.
func ensurePrivateOwnedDirectory(path string) error {
	return secureEncryptedStateDirectory(path, true)
}

func setRawDiscoCompatibility() {
	// Upstream registers this knob during package initialization, so os.Setenv
	// alone would change the environment without updating magicsock's cached
	// value. Use upstream's mutation path to keep both views consistent.
	envknob.Setenv(rawDiscoEnv, "false")
}

func (c *runtimeController) reserve(token uint64, config runtimeConfig) (*nodeRuntime, *nodeRuntime, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if token == 0 {
		return nil, nil, fmt.Errorf("runtime preparation token must be non-zero")
	}
	if err := c.cleanupAdmissionErrorLocked(); err != nil {
		return nil, nil, err
	}
	if _, abandoned := c.abandonedTokens[token]; abandoned {
		delete(c.abandonedTokens, token)
		return nil, nil, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if c.logout != nil {
		return nil, nil, fmt.Errorf("%w: logout token %d is still in progress", ErrLifecycleBusy, c.logout.token)
	}
	if c.reset != nil {
		return nil, nil, fmt.Errorf("%w: local reset token %d is still in progress", ErrLifecycleBusy, c.reset.token)
	}
	if c.persistentPreparation != nil || c.candidate != nil || c.draining != nil {
		return nil, nil, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	if c.current != nil {
		if c.current.config == config {
			return nil, c.current, nil
		}
		return nil, nil, fmt.Errorf("%w: call down before changing hostname, control URL, or ephemeral mode", ErrConfigurationMismatch)
	}

	candidate := newNodeRuntime(nodeEpoch.Load(), token, config)
	c.candidate = candidate
	return candidate, nil, nil
}

// refreshActiveRuntime handles the one persistent-start case that does not
// require new custody: an idempotent call against the already-active runtime.
// The admission decision runs under the controller lock; the refresh callback
// feeds the process-global host-network bridge, not runtime state, and runs
// after release per the ADR lock policy (no network work under c.mu). A
// separate host-network lock orders that process-global write with replacement
// starts, and the final admission check rejects a runtime detached meanwhile.
func (c *runtimeController) refreshActiveRuntime(
	token uint64,
	config runtimeConfig,
	refresh func() error,
) (*nodeRuntime, error) {
	// Serialize every host-network snapshot application without holding the
	// lifecycle mutex. A replacement start takes the same lock before applying
	// its snapshot, so an old active-runtime refresh can never overwrite the
	// replacement's newer process-global netmon state.
	c.hostNetworkMu.Lock()
	defer c.hostNetworkMu.Unlock()

	runtime, err := c.activeRuntimeForConfig(token, config)
	if err != nil || runtime == nil {
		return runtime, err
	}
	if refresh != nil {
		if err := refresh(); err != nil {
			return nil, err
		}
	}
	confirmed, err := c.activeRuntimeForConfig(token, config)
	if err != nil {
		return nil, err
	}
	if confirmed != runtime {
		return nil, fmt.Errorf("%w: active runtime changed during host-network refresh", ErrRuntimeStale)
	}
	return runtime, nil
}

func (c *runtimeController) applyHostNetworkSnapshot(
	snapshot string,
	dependencies runtimeStartDependencies,
) error {
	c.hostNetworkMu.Lock()
	defer c.hostNetworkMu.Unlock()
	return applyHostNetworkSnapshot(snapshot, dependencies)
}

func (c *runtimeController) activeRuntimeForConfig(
	token uint64,
	config runtimeConfig,
) (*nodeRuntime, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if token == 0 {
		return nil, fmt.Errorf("runtime preparation token must be non-zero")
	}
	if err := c.cleanupAdmissionErrorLocked(); err != nil {
		return nil, err
	}
	if _, abandoned := c.abandonedTokens[token]; abandoned {
		delete(c.abandonedTokens, token)
		return nil, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if c.logout != nil || c.reset != nil || c.candidate != nil || c.draining != nil {
		return nil, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	if preparation := c.persistentPreparation; preparation != nil {
		// A persistent start prepares and authenticates its Store before it
		// reaches this common active-runtime probe. The exact preparation token
		// is not a competing transition: let the caller continue to atomic
		// adoption. A different token must remain fail-closed and busy.
		if preparation.token == token && c.current == nil {
			return nil, nil
		}
		return nil, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	if c.current == nil {
		return nil, nil
	}
	if c.current.config != config {
		return nil, fmt.Errorf("%w: call down before changing hostname, control URL, or ephemeral mode", ErrConfigurationMismatch)
	}
	return c.current, nil
}

func (c *runtimeController) cleanupAdmissionErrorLocked() error {
	failure := c.cleanupFailure
	if failure == nil {
		return nil
	}
	return fmt.Errorf(
		"%w: token %d left native cleanup incomplete; restart the process before further lifecycle work: %v",
		ErrRuntimeCleanupFailed,
		failure.token,
		failure.err,
	)
}

func runtimeCleanupAdmissionError() error {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	return runtimes.cleanupAdmissionErrorLocked()
}

func (c *runtimeController) commit(candidate *nodeRuntime) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if candidate.abandoned {
		return fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, candidate.token)
	}
	if c.candidate != candidate || c.current != nil || c.draining != nil {
		return fmt.Errorf("%w: runtime reservation is no longer current", ErrLifecycleBusy)
	}
	c.candidate = nil
	c.current = candidate
	candidate.finishPreparation()
	return nil
}

func (c *runtimeController) isAbandoned(candidate *nodeRuntime) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return candidate == nil || candidate.abandoned || c.candidate != candidate
}

func (c *runtimeController) release(candidate *nodeRuntime, cleanupErr error) error {
	c.mu.Lock()
	cleanupErr = c.recordCleanupFailureLocked(candidate.token, cleanupErr)
	if c.candidate == candidate {
		c.candidate = nil
		if candidate.abandoned {
			mak.Set(&c.completedPreparations, candidate.token, preparationOutcome{err: cleanupErr})
		}
	}
	c.mu.Unlock()
	candidate.finishPreparationWithError(cleanupErr)
	return cleanupErr
}

func cleanupFailureError(err error) error {
	if err == nil || errors.Is(err, ErrRuntimeCleanupFailed) {
		return err
	}
	return fmt.Errorf("%w: %w", ErrRuntimeCleanupFailed, err)
}

func (c *runtimeController) recordCleanupFailureLocked(token uint64, err error) error {
	err = cleanupFailureError(err)
	if err != nil && c.cleanupFailure == nil {
		c.cleanupFailure = &runtimeCleanupFailure{token: token, err: err}
	}
	return err
}

func (c *runtimeController) recordCleanupFailure(token uint64, err error) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.recordCleanupFailureLocked(token, err)
}

func (c *runtimeController) recordLifecycleReceiptLocked(receipt lifecycleReceipt) {
	if receipt.result.Token == 0 {
		return
	}
	mak.Set(&c.completedLifecycle, receipt.result.Token, receipt)
}

func (c *runtimeController) recordLifecycleReceipt(receipt lifecycleReceipt) {
	c.mu.Lock()
	c.recordLifecycleReceiptLocked(receipt)
	c.mu.Unlock()
}

func (c *runtimeController) takeLifecycleReceiptLocked(token uint64) (lifecycleReceipt, bool) {
	receipt, ok := c.completedLifecycle[token]
	if ok {
		delete(c.completedLifecycle, token)
	}
	return receipt, ok
}

// AcknowledgeLifecycleResult retires a terminal receipt only after the caller
// isolate has received it. If the worker exits first, AbandonRuntime consumes
// the same receipt and returns the exact disposition instead.
func AcknowledgeLifecycleResult(token uint64) {
	if token == 0 {
		return
	}
	runtimes.mu.Lock()
	delete(runtimes.completedLifecycle, token)
	runtimes.mu.Unlock()
}

func currentRuntime() *nodeRuntime {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	return runtimes.current
}

// beginLogout reserves the exact current runtime through both upstream logout
// and runtime close. The StateStore container is deliberately retained;
// explicit local forget/reset owns physical key and file deletion.
func (c *runtimeController) beginLogout(runtime *nodeRuntime) (*logoutOperation, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if runtime == nil || runtime.token == 0 || c.current != runtime || runtime.ctx.Err() != nil {
		return nil, fmt.Errorf("%w: logout runtime is no longer current", ErrRuntimeStale)
	}
	if c.logout != nil {
		return nil, fmt.Errorf("%w: logout token %d is already in progress", ErrLifecycleBusy, c.logout.token)
	}
	op := &logoutOperation{token: runtime.token, done: make(chan struct{})}
	c.logout = op
	return op, nil
}

func (c *runtimeController) finishLogout(
	op *logoutOperation,
	result LogoutResult,
	operationErr error,
	cleanupErr error,
) {
	if op == nil {
		return
	}
	c.mu.Lock()
	if c.logout == op {
		cleanupErr = c.recordCleanupFailureLocked(op.token, cleanupErr)
		if op.cleanupErr == nil {
			op.cleanupErr = cleanupErr
		}
		c.recordLifecycleReceiptLocked(lifecycleReceipt{result: result.closeReceipt(), err: operationErr})
		c.logout = nil
		close(op.done)
	}
	c.mu.Unlock()
}

// RuntimeCloseResult is the event-silent native lifecycle result returned to
// the Dart supervisor. Started records an actual native detach; EmitStopped is
// the narrower caller-visible stream transition. Pending means a
// non-cancellable Server.Start is still unwinding; the token is already
// quarantined and cannot commit or admit a replacement runtime.
type RuntimeCloseResult struct {
	Token              uint64             `json:"token"`
	Operation          string             `json:"operation,omitempty"`
	Matched            bool               `json:"matched"`
	Started            bool               `json:"started"`
	EmitStopped        bool               `json:"emitStopped,omitempty"`
	Pending            bool               `json:"pending"`
	NoState            bool               `json:"noState,omitempty"`
	CleanupFailed      bool               `json:"cleanupFailed,omitempty"`
	CustodyHeld        bool               `json:"custodyHeld,omitempty"`
	CustodyDisposition CustodyDisposition `json:"custodyDisposition,omitempty"`
}

func detachRuntimeLocked(runtime *nodeRuntime, receiptOperation string) *drainingRuntime {
	runtimes.current = nil
	nodeEpoch.Add(1)
	draining := &drainingRuntime{
		runtime:          runtime,
		done:             make(chan struct{}),
		receiptOperation: receiptOperation,
	}
	runtimes.draining = draining
	return draining
}

func finishRuntimeDrain(draining *drainingRuntime, err error) error {
	runtimes.mu.Lock()
	if runtimes.draining == draining {
		err = runtimes.recordCleanupFailureLocked(draining.runtime.token, err)
		draining.err = err
		if logout := runtimes.logout; logout != nil && logout.token == draining.runtime.token {
			logout.cleanupErr = err
		}
		if draining.receiptOperation != "" {
			runtimes.recordLifecycleReceiptLocked(lifecycleReceipt{
				result: RuntimeCloseResult{
					Token:         draining.runtime.token,
					Operation:     draining.receiptOperation,
					Matched:       true,
					Started:       true,
					EmitStopped:   true,
					CleanupFailed: err != nil,
				},
				err: err,
			})
		}
		runtimes.draining = nil
		close(draining.done)
	}
	runtimes.mu.Unlock()
	return err
}

// AbandonRuntime quarantines exactly one supervisor-created token. It never
// closes a different or newer generation. A candidate inside Server.Start is
// marked abandoned and canceled but not closed concurrently; its construction
// path owns the eventual unwind.
func AbandonRuntime(token uint64) (RuntimeCloseResult, error) {
	result := RuntimeCloseResult{Token: token}
	if token == 0 {
		return result, nil
	}

	for {
		runtimes.mu.Lock()
		if receipt, ok := runtimes.takeLifecycleReceiptLocked(token); ok {
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return receipt.result, receipt.err
		}
		mak.Set(&runtimes.abandonedTokens, token, struct{}{})
		if preparation := runtimes.persistentPreparation; preparation != nil && preparation.token == token {
			custodyHeld, writeDone, disposition := preparation.abandonDisposition()
			result.Matched = true
			result.Pending = true
			runtimes.mu.Unlock()

			if writeDone != nil {
				<-writeDone
				disposition = preparation.custodyDisposition()
			}
			preparation.phaseMu.Lock()
			acquisitionSettled := preparation.acquisitionSettled
			preparation.phaseMu.Unlock()
			if !acquisitionSettled {
				return result, nil
			}
			if custodyHeld {
				result.CustodyHeld = true
				result.CustodyDisposition = disposition
				return result, nil
			}
			result.Pending = false
			finishErr := finishPersistentPreparation(preparation, nil)
			runtimes.mu.Lock()
			delete(runtimes.completedPreparations, token)
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return result, finishErr
		}
		if logout := runtimes.logout; logout != nil && logout.token == token {
			done := logout.done
			runtimes.mu.Unlock()
			<-done
			continue
		}
		if candidate := runtimes.candidate; candidate != nil && candidate.token == token {
			candidate.abandoned = true
			candidate.cancel()
			result.Matched = true
			result.Pending = true
			runtimes.mu.Unlock()
			return result, nil
		}
		if draining := runtimes.draining; draining != nil && draining.runtime.token == token {
			done := draining.done
			runtimes.mu.Unlock()
			<-done
			continue
		}
		runtime := runtimes.current
		if runtime == nil || runtime.token != token {
			// A token-qualified Start call can be executing before it has created
			// a candidate. Report a quiescence barrier without claiming that the
			// current (different-token) runtime matched this abandonment.
			if call := runtimes.startCalls[token]; call != nil {
				result.Pending = true
			}
			runtimes.mu.Unlock()
			return result, nil
		}
		draining := detachRuntimeLocked(runtime, "")
		result.Matched = true
		result.Started = true
		result.EmitStopped = true
		runtimes.mu.Unlock()

		err := runtime.close()
		finishErr := finishRuntimeDrain(draining, err)
		runtimes.mu.Lock()
		delete(runtimes.abandonedTokens, token)
		runtimes.mu.Unlock()
		return result, finishErr
	}
}

// AwaitRuntimeQuiescence joins a previously quarantined token without ever
// acting on a different generation. It is used before rebinding a replacement
// worker/push port after an abandoned non-cancellable Start.
func AwaitRuntimeQuiescence(token uint64) error {
	if token == 0 {
		return nil
	}
	for {
		runtimes.mu.Lock()
		if preparation := runtimes.persistentPreparation; preparation != nil && preparation.token == token {
			done := preparation.done
			runtimes.mu.Unlock()
			<-done
			err := preparation.result()
			runtimes.mu.Lock()
			delete(runtimes.completedPreparations, token)
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return err
		}
		if logout := runtimes.logout; logout != nil && logout.token == token {
			done := logout.done
			runtimes.mu.Unlock()
			<-done
			return logout.cleanupErr
		}
		if outcome, ok := runtimes.completedPreparations[token]; ok {
			delete(runtimes.completedPreparations, token)
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return outcome.err
		}
		var done <-chan struct{}
		var candidate *nodeRuntime
		var draining *drainingRuntime
		candidate = runtimes.candidate
		if candidate != nil && candidate.token == token {
			done = candidate.preparationDone
		} else {
			candidate = nil
			draining = runtimes.draining
		}
		if done == nil && draining != nil && draining.runtime.token == token {
			done = draining.done
		} else if done == nil {
			draining = nil
		}
		var startCall *runtimeStartCall
		if done == nil {
			startCall = runtimes.startCalls[token]
			if startCall != nil {
				done = startCall.done
			}
		}
		runtimes.mu.Unlock()
		if done == nil {
			return nil
		}
		<-done
		if startCall != nil {
			// The entry-call defer removes its tombstone before closing done.
			// Loop once more to consume any candidate cleanup receipt it left.
			continue
		}
		if candidate != nil {
			runtimes.mu.Lock()
			delete(runtimes.completedPreparations, token)
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return candidate.preparationErr
		}
		if draining != nil {
			runtimes.mu.Lock()
			delete(runtimes.abandonedTokens, token)
			runtimes.mu.Unlock()
			return draining.err
		}
	}
}

// CloseRuntime closes only the matching active token. A stale worker cannot
// use a delayed down acknowledgement to close a newer runtime.
func CloseRuntime(token uint64) (RuntimeCloseResult, error) {
	return closeRuntime(token, false)
}

// closeRuntime permits the logout owner to detach and close its own runtime
// while all public lifecycle callers remain joined to the wider logout
// operation through final state-directory disposition.
func closeRuntime(token uint64, logoutOwner bool) (RuntimeCloseResult, error) {
	result := RuntimeCloseResult{Token: token}
	if !logoutOwner {
		result.Operation = lifecycleOperationDown
	}
	if token == 0 {
		return result, nil
	}
	for {
		runtimes.mu.Lock()
		if logout := runtimes.logout; !logoutOwner && logout != nil && logout.token == token {
			done := logout.done
			result.Matched = true
			result.Started = true
			runtimes.mu.Unlock()
			<-done
			result.CleanupFailed = logout.cleanupErr != nil
			return result, logout.cleanupErr
		}
		if candidate := runtimes.candidate; candidate != nil {
			if candidate.token != token {
				runtimes.mu.Unlock()
				return result, nil
			}
			done := candidate.preparationDone
			result.Matched = true
			runtimes.mu.Unlock()
			<-done
			continue
		}
		if draining := runtimes.draining; draining != nil {
			if draining.runtime.token != token {
				runtimes.mu.Unlock()
				return result, nil
			}
			done := draining.done
			result.Matched = true
			result.Started = true
			result.EmitStopped = draining.receiptOperation == lifecycleOperationDown
			runtimes.mu.Unlock()
			<-done
			result.CleanupFailed = draining.err != nil
			return result, draining.err
		}
		runtime := runtimes.current
		if runtime == nil || runtime.token != token {
			runtimes.mu.Unlock()
			return result, nil
		}
		receiptOperation := ""
		if !logoutOwner {
			receiptOperation = lifecycleOperationDown
		}
		draining := detachRuntimeLocked(runtime, receiptOperation)
		result.Matched = true
		result.Started = true
		result.EmitStopped = !logoutOwner
		runtimes.mu.Unlock()

		err := runtime.close()
		err = finishRuntimeDrain(draining, err)
		result.CleanupFailed = err != nil
		return result, err
	}
}

func closeRuntimeForLogout(token uint64) (RuntimeCloseResult, error) {
	return closeRuntime(token, true)
}

// closeCurrentRuntime detaches and bumps the epoch under the controller lock,
// then performs blocking cleanup outside it. A concurrent repeated close waits
// for the first close and remains an idempotent no-op.
func closeCurrentRuntime() (bool, error) {
	for {
		runtimes.mu.Lock()
		if logout := runtimes.logout; logout != nil {
			done := logout.done
			runtimes.mu.Unlock()
			<-done
			return false, logout.cleanupErr
		}
		if runtimes.candidate != nil {
			done := runtimes.candidate.preparationDone
			runtimes.mu.Unlock()
			<-done
			continue
		}
		if draining := runtimes.draining; draining != nil {
			done := draining.done
			runtimes.mu.Unlock()
			<-done
			return false, draining.err
		}
		runtime := runtimes.current
		if runtime == nil {
			runtimes.mu.Unlock()
			return false, nil
		}
		draining := detachRuntimeLocked(runtime, "")
		runtimes.mu.Unlock()

		err := runtime.close()
		return true, finishRuntimeDrain(draining, err)
	}
}
