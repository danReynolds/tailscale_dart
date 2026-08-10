package tailscale

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
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

type runtimeConfig struct {
	hostname   string
	controlURL string
	ephemeral  bool
}

// nodeRuntime owns everything whose lifetime is exactly one tsnet.Server
// generation. Process-global registries remain as a compatibility bridge for
// now, but their teardown is centralized in close.
type nodeRuntime struct {
	generation uint64
	token      uint64
	config     runtimeConfig

	ctx    context.Context
	cancel context.CancelFunc

	server      *tsnet.Server
	localClient *local.Client
	store       ipn.StateStore
	storeCloser io.Closer
	closeServer func(*tsnet.Server) error

	preparationDone     chan struct{}
	preparationDoneOnce sync.Once
	preparationErr      error
	closeOnce           sync.Once
	closeErr            error
	abandoned           bool // guarded by runtimeController.mu
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

// close is the sole post-Start teardown path. The epoch is bumped and the
// runtime detached by runtimeController before this method runs, so slow
// registry cleanup and Server.Close happen without the controller lock held.
// The Server is always closed before its caller-owned StateStore.
func (r *nodeRuntime) close() error {
	if r == nil {
		return nil
	}
	r.closeOnce.Do(func() {
		r.cancel()

		closeAllServePublications(r.localClient)
		closeAllTcpFdListeners()
		closeAllHttpBindings()
		closeAllFunnelForwarders()
		closeAllUdpBindings()
		resetTailnetHTTPTransport()
		StopWatch()

		if r.server != nil {
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
	mu          sync.Mutex
	configureMu sync.Mutex

	candidate             *nodeRuntime
	current               *nodeRuntime
	draining              *drainingRuntime
	logout                *logoutOperation
	abandonedTokens       map[uint64]struct{}
	completedPreparations map[uint64]preparationOutcome
	completedLifecycle    map[uint64]lifecycleReceipt
	cleanupFailure        *runtimeCleanupFailure
	lastConfig            *runtimeConfig

	configured    bool
	stateRoot     string
	stateRootInfo os.FileInfo
	logLevel      int32
}

var runtimes runtimeController

// Configure freezes process-wide initialization identity. os.SameFile supplies
// native path/inode identity, so lexical and symlink aliases cannot create two
// owners for the same state root.
func Configure(stateRoot string, logLevel int32) (string, error) {
	runtimes.configureMu.Lock()
	defer runtimes.configureMu.Unlock()

	if strings.TrimSpace(stateRoot) == "" {
		return "", fmt.Errorf("state directory is empty")
	}
	if logLevel < 0 || logLevel > 2 {
		return "", fmt.Errorf("invalid log level %d", logLevel)
	}

	abs, err := filepath.Abs(stateRoot)
	if err != nil {
		return "", fmt.Errorf("resolve state directory: %w", err)
	}
	abs = filepath.Clean(abs)

	runtimes.mu.Lock()
	alreadyConfigured := runtimes.configured
	configuredRoot := runtimes.stateRoot
	configuredRootInfo := runtimes.stateRootInfo
	configuredLogLevel := runtimes.logLevel
	runtimes.mu.Unlock()
	if alreadyConfigured {
		if configuredLogLevel != logLevel {
			return "", fmt.Errorf("%w: Tailscale.init already owns a different state root or log level", ErrConfigurationMismatch)
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
			return "", fmt.Errorf("%w: Tailscale.init already owns a different state root or log level", ErrConfigurationMismatch)
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
	if err := setRawDiscoCompatibility(); err != nil {
		return "", err
	}
	runtimes.configured = true
	runtimes.stateRoot = resolved
	runtimes.stateRootInfo = info
	runtimes.logLevel = logLevel
	atomic.StoreInt32(&LogLevel, logLevel)
	return resolved, nil
}

const ownedStateSubdirectory = "tailscale"

// configuredStateDir returns the only state directory native lifecycle calls
// may use. The root inode is revalidated so deleting/replacing the configured
// directory cannot silently redirect credentials to a different filesystem
// object at the same lexical path.
func configuredStateDir() (string, error) {
	runtimes.mu.Lock()
	configured := runtimes.configured
	root := runtimes.stateRoot
	rootInfo := runtimes.stateRootInfo
	runtimes.mu.Unlock()
	if !configured || rootInfo == nil {
		return "", fmt.Errorf("%w: call Tailscale.init before using the native runtime", ErrConfigurationMismatch)
	}

	info, err := os.Stat(root)
	if err != nil {
		return "", fmt.Errorf("%w: configured state root is unavailable: %v", ErrConfigurationMismatch, err)
	}
	if !os.SameFile(rootInfo, info) {
		return "", fmt.Errorf("%w: configured state root was replaced", ErrConfigurationMismatch)
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
// storage boundaries and must remain real directories.
func ensurePrivateOwnedDirectory(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}

	before, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if before.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("path is a symbolic link")
	}
	if !before.IsDir() {
		return fmt.Errorf("path is not a directory")
	}

	// Chmod the verified directory handle, not the path. Revalidate its path
	// identity before and after mutation so a swapped symlink or directory is
	// rejected without chmodding an external target.
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	opened, err := dir.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.IsDir() || !os.SameFile(opened, current) {
		return fmt.Errorf("directory identity changed while securing it")
	}
	if err := dir.Chmod(0o700); err != nil {
		return err
	}
	final, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if final.Mode()&os.ModeSymlink != 0 || !final.IsDir() || !os.SameFile(opened, final) {
		return fmt.Errorf("directory identity changed while securing it")
	}
	if got := final.Mode().Perm(); got != 0o700 {
		return fmt.Errorf("permissions are %04o, want 0700", got)
	}
	return nil
}

// removeOwnedDirectory refuses ambiguous package-owned paths. RemoveAll does
// not follow a terminal symlink, which protects its target but could otherwise
// make logout report success while credentials remain in that target.
func removeOwnedDirectory(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("path is a symbolic link")
	}
	if !info.IsDir() {
		return fmt.Errorf("path is not a directory")
	}
	return os.RemoveAll(path)
}

func setRawDiscoCompatibility() error {
	if err := os.Setenv("TS_ENABLE_RAW_DISCO", "false"); err != nil {
		return fmt.Errorf("configure TS_ENABLE_RAW_DISCO compatibility: %w", err)
	}
	return nil
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
		return nil, nil, fmt.Errorf("%w: preparation token %d", ErrStartupAbandoned, token)
	}
	if c.logout != nil {
		return nil, nil, fmt.Errorf("%w: logout token %d is still in progress", ErrLifecycleBusy, c.logout.token)
	}
	if c.candidate != nil || c.draining != nil {
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
	// A fresh Server.Start may persist Hostname/ControlURL before the runtime
	// can commit. Invalidate any older tuple now; rememberStartedConfig restores
	// only a configuration that a successful Start proved was applied.
	c.lastConfig = nil
	return candidate, nil, nil
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

func (c *runtimeController) rememberStartedConfig(candidate *nodeRuntime) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if candidate != nil && c.candidate == candidate {
		config := candidate.config
		c.lastConfig = &config
	}
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
	config := candidate.config
	c.lastConfig = &config
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
			if c.completedPreparations == nil {
				c.completedPreparations = make(map[uint64]preparationOutcome)
			}
			c.completedPreparations[candidate.token] = preparationOutcome{err: cleanupErr}
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
	if c.completedLifecycle == nil {
		c.completedLifecycle = make(map[uint64]lifecycleReceipt)
	}
	c.completedLifecycle[receipt.result.Token] = receipt
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

func lastRuntimeConfig() (runtimeConfig, error) {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	if runtimes.lastConfig == nil {
		return runtimeConfig{}, fmt.Errorf(
			"%w: persisted identity cannot be safely reopened for logout; start it once with its original hostname, control URL, and ephemeral mode",
			ErrConfigurationMismatch,
		)
	}
	return *runtimes.lastConfig, nil
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
		c.recordLifecycleReceiptLocked(lifecycleReceipt{
			result: RuntimeCloseResult{
				Token:         result.Token,
				Operation:     lifecycleOperationLogout,
				Matched:       true,
				Started:       result.Started,
				EmitStopped:   result.EmitStopped,
				NoState:       result.NoState,
				CleanupFailed: result.CleanupFailed,
			},
			err: operationErr,
		})
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
	Token         uint64 `json:"token"`
	Operation     string `json:"operation,omitempty"`
	Matched       bool   `json:"matched"`
	Started       bool   `json:"started"`
	EmitStopped   bool   `json:"emitStopped,omitempty"`
	Pending       bool   `json:"pending"`
	NoState       bool   `json:"noState,omitempty"`
	CleanupFailed bool   `json:"cleanupFailed,omitempty"`
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
			runtimes.mu.Unlock()
			return receipt.result, receipt.err
		}
		if runtimes.abandonedTokens == nil {
			runtimes.abandonedTokens = make(map[uint64]struct{})
		}
		runtimes.abandonedTokens[token] = struct{}{}
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
			runtimes.mu.Unlock()
			return result, nil
		}
		draining := detachRuntimeLocked(runtime, "")
		result.Matched = true
		result.Started = true
		result.EmitStopped = true
		runtimes.mu.Unlock()

		err := runtime.close()
		return result, finishRuntimeDrain(draining, err)
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
		if logout := runtimes.logout; logout != nil && logout.token == token {
			done := logout.done
			runtimes.mu.Unlock()
			<-done
			return logout.cleanupErr
		}
		if outcome, ok := runtimes.completedPreparations[token]; ok {
			delete(runtimes.completedPreparations, token)
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
		runtimes.mu.Unlock()
		if done == nil {
			return nil
		}
		<-done
		if candidate != nil {
			runtimes.mu.Lock()
			delete(runtimes.completedPreparations, token)
			runtimes.mu.Unlock()
			return candidate.preparationErr
		}
		if draining != nil {
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

// IdleStateClass is conservative filesystem occupancy, not enrollment truth.
// R4 replaces the policy behind this seam with the authenticated secure-state
// matrix while retaining exact legacy recognition.
type IdleStateClass string

const (
	IdleStateAbsent IdleStateClass = "absent"
	IdleStateLegacy IdleStateClass = "legacy"
)

// ClassifyIdleState recognizes legacy SQLite artifacts without opening or
// creating a database. A machine key is not proof of enrollment, and this
// classifier deliberately never reads one.
func ClassifyIdleState(stateDir string) (IdleStateClass, error) {
	if strings.TrimSpace(stateDir) == "" {
		return "", fmt.Errorf("state directory is empty")
	}
	for _, name := range [...]string{"state.db", "state.db-wal", "state.db-shm"} {
		_, err := os.Lstat(filepath.Join(stateDir, name))
		switch {
		case err == nil:
			return IdleStateLegacy, nil
		case os.IsNotExist(err):
			continue
		default:
			return "", fmt.Errorf("inspect legacy state artifact %q: %w", name, err)
		}
	}
	return IdleStateAbsent, nil
}

// ClassifyConfiguredIdleState applies the idle classifier only to the
// process-owned state subtree selected by Configure.
func ClassifyConfiguredIdleState() (IdleStateClass, error) {
	stateDir, err := configuredStateDir()
	if err != nil {
		return "", err
	}
	return ClassifyIdleState(stateDir)
}
