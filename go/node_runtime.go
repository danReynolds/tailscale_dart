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

// ErrConfigurationMismatch means an immutable process or active-runtime
// setting differs from the value that already owns this process.
var ErrConfigurationMismatch = errors.New("tailscale configuration mismatch")

// ErrRuntimeStale means an operation captured a runtime generation that has
// since been detached or canceled.
var ErrRuntimeStale = errors.New("tailscale runtime stopped or stale")

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
	closeOnce           sync.Once
	closeErr            error
}

func newNodeRuntime(generation uint64, config runtimeConfig) *nodeRuntime {
	ctx, cancel := context.WithCancel(context.Background())
	return &nodeRuntime{
		generation:      generation,
		config:          config,
		ctx:             ctx,
		cancel:          cancel,
		preparationDone: make(chan struct{}),
	}
}

func (r *nodeRuntime) finishPreparation() {
	r.preparationDoneOnce.Do(func() { close(r.preparationDone) })
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
	runtime *nodeRuntime
	done    chan struct{}
}

// runtimeController is the single owner of candidate/current/draining runtime
// state and immutable package configuration.
type runtimeController struct {
	mu          sync.Mutex
	configureMu sync.Mutex

	candidate *nodeRuntime
	current   *nodeRuntime
	draining  *drainingRuntime

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

func (c *runtimeController) reserve(config runtimeConfig) (*nodeRuntime, *nodeRuntime, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.candidate != nil || c.draining != nil {
		return nil, nil, fmt.Errorf("%w: another node lifecycle transition is in progress", ErrLifecycleBusy)
	}
	if c.current != nil {
		if c.current.config == config {
			return nil, c.current, nil
		}
		return nil, nil, fmt.Errorf("%w: call down before changing hostname, control URL, or ephemeral mode", ErrConfigurationMismatch)
	}

	candidate := newNodeRuntime(nodeEpoch.Load(), config)
	c.candidate = candidate
	return candidate, nil, nil
}

func (c *runtimeController) commit(candidate *nodeRuntime) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.candidate != candidate || c.current != nil || c.draining != nil {
		return fmt.Errorf("%w: runtime reservation is no longer current", ErrLifecycleBusy)
	}
	c.candidate = nil
	c.current = candidate
	candidate.finishPreparation()
	return nil
}

func (c *runtimeController) release(candidate *nodeRuntime) {
	c.mu.Lock()
	if c.candidate == candidate {
		c.candidate = nil
	}
	c.mu.Unlock()
	candidate.finishPreparation()
}

func currentRuntime() *nodeRuntime {
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	return runtimes.current
}

// closeCurrentRuntime detaches and bumps the epoch under the controller lock,
// then performs blocking cleanup outside it. A concurrent repeated close waits
// for the first close and remains an idempotent no-op.
func closeCurrentRuntime() (bool, error) {
	for {
		runtimes.mu.Lock()
		if runtimes.candidate != nil {
			done := runtimes.candidate.preparationDone
			runtimes.mu.Unlock()
			<-done
			continue
		}
		if runtimes.draining != nil {
			done := runtimes.draining.done
			runtimes.mu.Unlock()
			<-done
			return false, nil
		}
		runtime := runtimes.current
		if runtime == nil {
			runtimes.mu.Unlock()
			return false, nil
		}
		runtimes.current = nil
		nodeEpoch.Add(1)
		draining := &drainingRuntime{runtime: runtime, done: make(chan struct{})}
		runtimes.draining = draining
		runtimes.mu.Unlock()

		err := runtime.close()

		runtimes.mu.Lock()
		if runtimes.draining == draining {
			runtimes.draining = nil
			close(draining.done)
		}
		runtimes.mu.Unlock()
		return true, err
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
