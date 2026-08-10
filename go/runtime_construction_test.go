package tailscale

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

type recordingStateStore struct {
	closeCalls atomic.Int32
	onClose    func()
}

func (*recordingStateStore) ReadState(ipn.StateKey) ([]byte, error) {
	return nil, ipn.ErrStateNotExist
}

func (*recordingStateStore) WriteState(ipn.StateKey, []byte) error { return nil }

func (s *recordingStateStore) Close() error {
	s.closeCalls.Add(1)
	if s.onClose != nil {
		s.onClose()
	}
	return nil
}

func constructionDependencies(
	store *recordingStateStore,
	start func(*tsnet.Server) error,
	client func(*tsnet.Server) (*local.Client, error),
	closeServer func(*tsnet.Server) error,
) runtimeStartDependencies {
	return runtimeStartDependencies{
		openStore: func(string) (ipn.StateStore, io.Closer, error) {
			return store, store, nil
		},
		configureHostNetwork: ConfigureHostNetworkSnapshot,
		startServer:          start,
		localClient:          client,
		closeServer:          closeServer,
	}
}

func TestRuntimeConstruction_StartFailureNeverClosesServer(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	store := new(recordingStateStore)
	var serverCloseCalls atomic.Int32
	startFailure := errors.New("injected Start failure")
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error { return startFailure },
		func(*tsnet.Server) (*local.Client, error) {
			t.Fatal("LocalClient called after Start failure")
			return nil, nil
		},
		func(*tsnet.Server) error {
			serverCloseCalls.Add(1)
			return nil
		},
	)

	_, err := startRuntimeWithDependencies("node", "", "https://control/", stateDir, false, "", deps)
	if !errors.Is(err, startFailure) {
		t.Fatalf("start error = %v, want injected failure", err)
	}
	if got := serverCloseCalls.Load(); got != 0 {
		t.Fatalf("Server.Close calls = %d after Start failure, want 0", got)
	}
	if got := store.closeCalls.Load(); got != 1 {
		t.Fatalf("Store.Close calls = %d after Start failure, want 1", got)
	}
}

func TestRuntimeConstruction_PostStartFailureClosesServerBeforeStore(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	var mu sync.Mutex
	events := []string{}
	record := func(event string) {
		mu.Lock()
		events = append(events, event)
		mu.Unlock()
	}
	store := &recordingStateStore{onClose: func() { record("store") }}
	clientFailure := errors.New("injected LocalClient failure")
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error { return nil },
		func(*tsnet.Server) (*local.Client, error) { return nil, clientFailure },
		func(*tsnet.Server) error {
			record("server")
			return nil
		},
	)

	_, err := startRuntimeWithDependencies("node", "", "https://control/", stateDir, false, "", deps)
	if !errors.Is(err, clientFailure) {
		t.Fatalf("start error = %v, want LocalClient failure", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(events) != 2 || events[0] != "server" || events[1] != "store" {
		t.Fatalf("close order = %v, want [server store]", events)
	}
}

func TestRuntimeConstruction_CachesPrivateDialClientBeforeCommit(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	var closeMu sync.Mutex
	closeEvents := []string{}
	recordClose := func(event string) {
		closeMu.Lock()
		closeEvents = append(closeEvents, event)
		closeMu.Unlock()
	}
	store := &recordingStateStore{onClose: func() { recordClose("store") }}
	var dialCalls atomic.Int32
	dialFailure := errors.New("sentinel private dial")
	lc := &local.Client{
		Dial: func(context.Context, string, string) (net.Conn, error) {
			dialCalls.Add(1)
			return nil, dialFailure
		},
	}
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error { return nil },
		func(*tsnet.Server) (*local.Client, error) { return lc, nil },
		func(*tsnet.Server) error {
			recordClose("server")
			return nil
		},
	)

	if _, err := startRuntimeWithDependencies("node", "", "https://control/", stateDir, false, "", deps); err != nil {
		t.Fatalf("startRuntimeWithDependencies: %v", err)
	}
	runtime := currentRuntime()
	if runtime == nil || runtime.localClient != lc {
		t.Fatal("runtime did not cache the constructed LocalClient")
	}
	if !runtime.localClient.OmitAuth {
		t.Fatal("cached LocalClient did not enable OmitAuth before commit")
	}
	if runtime.localClient.Dial == nil {
		t.Fatal("cached LocalClient lost tsnet's private Dial function")
	}
	if _, err := runtime.localClient.Dial(context.Background(), "tcp", "local-tailscaled"); !errors.Is(err, dialFailure) {
		t.Fatalf("cached Dial error = %v, want sentinel private dial", err)
	}
	if got := dialCalls.Load(); got != 1 {
		t.Fatalf("cached Dial calls = %d, want 1", got)
	}
	if _, err := closeCurrentRuntime(); err != nil {
		t.Fatalf("closeCurrentRuntime: %v", err)
	}
	closeMu.Lock()
	defer closeMu.Unlock()
	if len(closeEvents) != 2 || closeEvents[0] != "server" || closeEvents[1] != "store" {
		t.Fatalf("normal close order = %v, want [server store]", closeEvents)
	}
}

func TestRuntimeConstruction_ProductionLocalClientUsesPrivateDial(t *testing.T) {
	configureFreshStateRootForTest(t)
	if _, err := StartRuntime("local-client-trust", "", "", false); err != nil {
		t.Fatalf("StartRuntime: %v", err)
	}

	runtime := currentRuntime()
	if runtime == nil || runtime.localClient == nil {
		t.Fatal("production runtime did not cache a LocalClient")
	}
	if !runtime.localClient.OmitAuth {
		t.Fatal("production LocalClient did not enable OmitAuth")
	}
	if runtime.localClient.Dial == nil {
		t.Fatal("upstream tsnet LocalClient lost its private in-process Dial")
	}

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if _, err := runtime.localClient.StatusWithoutPeers(ctx); err != nil {
		t.Fatalf("production LocalClient private-Dial status request: %v", err)
	}
}

func TestRuntimeConstruction_ActiveRefreshesHostNetworkAfterConfigValidation(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	config := runtimeConfig{
		hostname:   "same-node",
		controlURL: "https://control.example/",
	}
	withActiveRuntimeForTest(t, config)

	var snapshots []string
	deps := runtimeStartDependencies{
		configureHostNetwork: func(snapshot string) error {
			snapshots = append(snapshots, snapshot)
			return nil
		},
	}

	alreadyActive, err := startRuntimeWithDependencies(
		config.hostname,
		"ignored-auth-key",
		config.controlURL,
		stateDir,
		config.ephemeral,
		`{"interfaces":[{"name":"wlan0"}]}`,
		deps,
	)
	if err != nil || !alreadyActive {
		t.Fatalf("same-config start = (%v, %v), want active success", alreadyActive, err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("host snapshot updates = %v, want one active refresh", snapshots)
	}

	_, err = startRuntimeWithDependencies(
		"different-node",
		"",
		config.controlURL,
		stateDir,
		config.ephemeral,
		`{"interfaces":[{"name":"mutating-mismatch"}]}`,
		deps,
	)
	if !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("mismatched start error = %v, want ErrConfigurationMismatch", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("configuration mismatch mutated host snapshot: %v", snapshots)
	}
}

func TestRuntimeConstruction_RestoresExactLogsEnvironment(t *testing.T) {
	tests := []struct {
		name     string
		present  bool
		value    string
		startErr error
	}{
		{name: "absent"},
		{name: "empty", present: true, value: ""},
		{name: "nonempty", present: true, value: "embedding-app-logs"},
		{name: "start error", present: true, value: "before-error", startErr: errors.New("start failed")},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stateDir := configureFreshStateRootForTest(t)
			previous, hadPrevious := os.LookupEnv("TS_LOGS_DIR")
			t.Cleanup(func() {
				if hadPrevious {
					_ = os.Setenv("TS_LOGS_DIR", previous)
				} else {
					_ = os.Unsetenv("TS_LOGS_DIR")
				}
			})
			if tt.present {
				if err := os.Setenv("TS_LOGS_DIR", tt.value); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Unsetenv("TS_LOGS_DIR"); err != nil {
				t.Fatal(err)
			}

			store := new(recordingStateStore)
			deps := constructionDependencies(
				store,
				func(*tsnet.Server) error {
					if got := os.Getenv("TS_LOGS_DIR"); got != filepath.Join(stateDir, "logs") {
						t.Fatalf("TS_LOGS_DIR during Start = %q", got)
					}
					return tt.startErr
				},
				func(*tsnet.Server) (*local.Client, error) { return &local.Client{}, nil },
				func(*tsnet.Server) error { return nil },
			)

			_, err := startRuntimeWithDependencies("node", "", "https://control/", stateDir, false, "", deps)
			if !errors.Is(err, tt.startErr) {
				t.Fatalf("start error = %v, want %v", err, tt.startErr)
			}
			got, present := os.LookupEnv("TS_LOGS_DIR")
			if present != tt.present || got != tt.value {
				t.Fatalf("restored TS_LOGS_DIR = (%q, %v), want (%q, %v)", got, present, tt.value, tt.present)
			}
		})
	}
}

func TestRuntimeConstruction_TightensExistingLogDirectory(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	logDir := filepath.Join(stateDir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	store := new(recordingStateStore)
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error { return nil },
		func(*tsnet.Server) (*local.Client, error) { return &local.Client{}, nil },
		func(*tsnet.Server) error { return nil },
	)

	if _, err := startRuntimeWithDependencies("node", "", "https://control/", stateDir, false, "", deps); err != nil {
		t.Fatalf("startRuntimeWithDependencies: %v", err)
	}
	info, err := os.Stat(logDir)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("log directory permissions = %04o, want 0700", got)
	}
}

func TestRuntimeConstruction_RejectsSymlinkedOwnedDirectoriesWithoutTouchingTargets(t *testing.T) {
	for _, component := range []string{"tailscale", "logs"} {
		t.Run(component, func(t *testing.T) {
			stateDir := configureFreshStateRootForTest(t)
			if component == "logs" {
				if err := os.Mkdir(stateDir, 0o700); err != nil {
					t.Fatal(err)
				}
			}

			target := t.TempDir()
			if err := os.Chmod(target, 0o755); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(target, "keep")
			if err := os.WriteFile(marker, []byte("external"), 0o600); err != nil {
				t.Fatal(err)
			}
			link := stateDir
			if component == "logs" {
				link = filepath.Join(stateDir, "logs")
			}
			if err := os.Symlink(target, link); err != nil {
				t.Skipf("symlinks unavailable: %v", err)
			}

			storeOpened := false
			deps := runtimeStartDependencies{
				openStore: func(string) (ipn.StateStore, io.Closer, error) {
					storeOpened = true
					return nil, nil, errors.New("store must not open")
				},
				configureHostNetwork: func(string) error { return nil },
			}
			if _, err := startRuntimeWithDependencies("node", "", "", stateDir, false, "", deps); err == nil {
				t.Fatal("start accepted a symlinked package-owned directory")
			}
			if storeOpened {
				t.Fatal("store opened through a symlinked package-owned directory")
			}
			got, err := os.ReadFile(marker)
			if err != nil || string(got) != "external" {
				t.Fatalf("external target marker = %q, %v; want untouched", got, err)
			}
			info, err := os.Stat(target)
			if err != nil {
				t.Fatal(err)
			}
			if got := info.Mode().Perm(); got != 0o755 {
				t.Fatalf("external target permissions = %04o, want untouched 0755", got)
			}
			if _, err := os.Stat(filepath.Join(target, "logs")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("external target gained package logs directory: %v", err)
			}
		})
	}
}

func TestRuntimeConstruction_RejectsWrongTypeOwnedDirectoriesBeforeStoreOpen(t *testing.T) {
	for _, component := range []string{"tailscale", "logs"} {
		t.Run(component, func(t *testing.T) {
			stateDir := configureFreshStateRootForTest(t)
			path := stateDir
			if component == "logs" {
				if err := os.Mkdir(stateDir, 0o700); err != nil {
					t.Fatal(err)
				}
				path = filepath.Join(stateDir, "logs")
			}
			if err := os.WriteFile(path, []byte("not a directory"), 0o600); err != nil {
				t.Fatal(err)
			}

			storeOpened := false
			deps := runtimeStartDependencies{
				openStore: func(string) (ipn.StateStore, io.Closer, error) {
					storeOpened = true
					return nil, nil, errors.New("store must not open")
				},
				configureHostNetwork: func(string) error { return nil },
			}
			if _, err := startRuntimeWithDependencies("node", "", "", stateDir, false, "", deps); err == nil {
				t.Fatal("start accepted a non-directory package-owned path")
			}
			if storeOpened {
				t.Fatal("store opened through a non-directory package-owned path")
			}
			got, err := os.ReadFile(path)
			if err != nil || string(got) != "not a directory" {
				t.Fatalf("wrong-type path = %q, %v; want untouched", got, err)
			}
		})
	}
}

func TestRuntimeClose_DoesNotHoldControllerLockWhileDraining(t *testing.T) {
	configureFreshStateRootForTest(t)
	enteredClose := make(chan struct{})
	releaseClose := make(chan struct{})
	runtime := newNodeRuntime(nodeEpoch.Load(), runtimeConfig{})
	runtime.server = &tsnet.Server{}
	runtime.closeServer = func(*tsnet.Server) error {
		close(enteredClose)
		<-releaseClose
		return nil
	}
	runtime.finishPreparation()
	runtimes.mu.Lock()
	runtimes.current = runtime
	runtimes.mu.Unlock()

	closeDone := make(chan error, 1)
	go func() {
		_, err := closeCurrentRuntime()
		closeDone <- err
	}()
	<-enteredClose

	lockAcquired := make(chan struct{})
	go func() {
		runtimes.mu.Lock()
		runtimes.mu.Unlock()
		close(lockAcquired)
	}()
	select {
	case <-lockAcquired:
	case <-time.After(time.Second):
		t.Fatal("runtimeController.mu remained held during blocking close")
	}
	close(releaseClose)
	if err := <-closeDone; err != nil {
		t.Fatalf("closeCurrentRuntime: %v", err)
	}
}
