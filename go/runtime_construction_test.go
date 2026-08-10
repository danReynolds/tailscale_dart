package tailscale

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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
	mu         sync.Mutex
	values     map[ipn.StateKey][]byte
}

func (s *recordingStateStore) ReadState(key ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value, ok := s.values[key]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return bytes.Clone(value), nil
}

func (s *recordingStateStore) WriteState(key ipn.StateKey, value []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if value == nil {
		delete(s.values, key)
		return nil
	}
	if s.values == nil {
		s.values = make(map[ipn.StateKey][]byte)
	}
	s.values[key] = bytes.Clone(value)
	return nil
}

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
		adoptPersistent: func(token uint64, config runtimeConfig) (*nodeRuntime, error) {
			candidate, active, err := runtimes.reserve(token, config)
			if err != nil {
				return nil, err
			}
			if active != nil {
				return nil, fmt.Errorf("test adoption unexpectedly found an active runtime")
			}
			root, expectedRoot, err := configuredStateRootSnapshot()
			if err != nil {
				_ = runtimes.release(candidate, nil)
				return nil, err
			}
			lease, err := acquireStateLease(root, withExpectedStateLeaseRoot(expectedRoot))
			if err != nil {
				_ = runtimes.release(candidate, nil)
				return nil, err
			}
			candidate.stateLease = lease
			stateDir, err := configuredStateDir()
			if err == nil {
				err = ensurePrivateOwnedDirectory(stateDir)
			}
			if err != nil {
				cleanupErr := candidate.closeUnstarted()
				_ = runtimes.release(candidate, cleanupErr)
				return nil, err
			}
			candidate.store = store
			candidate.storeCloser = store
			return candidate, nil
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

func TestRuntimeConstruction_MetadataRequiresSuccessfulServerStart(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	oldConfig := runtimeConfig{hostname: "old-node", controlURL: "https://old.example/"}
	newConfig := runtimeConfig{hostname: "new-node", controlURL: "https://new.example/"}
	startFailure := errors.New("injected Start failure")

	failedStore := new(recordingStateStore)
	if err := saveRuntimeConfig(failedStore, oldConfig); err != nil {
		t.Fatalf("seed old runtime metadata: %v", err)
	}
	failedDeps := constructionDependencies(
		failedStore,
		func(*tsnet.Server) error {
			if _, err := loadRuntimeConfig(failedStore); !errors.Is(err, ipn.ErrStateNotExist) {
				t.Fatalf("metadata visible during unproven Start: %v", err)
			}
			return startFailure
		},
		func(*tsnet.Server) (*local.Client, error) {
			t.Fatal("LocalClient called after Start failure")
			return nil, nil
		},
		func(*tsnet.Server) error { return nil },
	)
	if _, err := startRuntimeWithDependencies(
		newConfig.hostname,
		"",
		newConfig.controlURL,
		stateDir,
		false,
		"",
		failedDeps,
	); !errors.Is(err, startFailure) {
		t.Fatalf("failed start error = %v, want %v", err, startFailure)
	}
	if _, err := loadRuntimeConfig(failedStore); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("failed Start retained a trusted runtime tuple: %v", err)
	}

	successStore := new(recordingStateStore)
	if err := saveRuntimeConfig(successStore, oldConfig); err != nil {
		t.Fatalf("seed successful-path metadata: %v", err)
	}
	successDeps := constructionDependencies(
		successStore,
		func(*tsnet.Server) error {
			if _, err := loadRuntimeConfig(successStore); !errors.Is(err, ipn.ErrStateNotExist) {
				t.Fatalf("old metadata visible during fresh Start: %v", err)
			}
			return nil
		},
		func(*tsnet.Server) (*local.Client, error) { return &local.Client{}, nil },
		func(*tsnet.Server) error { return nil },
	)
	alreadyActive, err := startRuntimeWithDependencies(
		newConfig.hostname,
		"",
		newConfig.controlURL,
		stateDir,
		false,
		"",
		successDeps,
	)
	if err != nil || alreadyActive {
		t.Fatalf("successful start = (%v, %v), want fresh success", alreadyActive, err)
	}
	if got, err := loadRuntimeConfig(successStore); err != nil || got != newConfig {
		t.Fatalf("proven runtime metadata = (%+v, %v), want %+v", got, err, newConfig)
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
	if err := saveRuntimeConfig(store, runtimeConfig{hostname: "old-node"}); err != nil {
		t.Fatalf("seed old runtime metadata: %v", err)
	}
	newConfig := runtimeConfig{
		hostname:   "node",
		controlURL: "https://control/",
	}
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

	_, err := startRuntimeWithDependencies(
		newConfig.hostname,
		"",
		newConfig.controlURL,
		stateDir,
		false,
		"",
		deps,
	)
	if !errors.Is(err, clientFailure) {
		t.Fatalf("start error = %v, want LocalClient failure", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(events) != 2 || events[0] != "server" || events[1] != "store" {
		t.Fatalf("close order = %v, want [server store]", events)
	}
	if got, metadataErr := loadRuntimeConfig(store); metadataErr != nil || got != newConfig {
		t.Fatalf(
			"post-Start metadata = (%+v, %v), want proven tuple %+v",
			got,
			metadataErr,
			newConfig,
		)
	}
}

func TestRuntimeConstruction_AbandonedStartCannotCommitLateSuccess(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	const token uint64 = 71001
	enteredStart := make(chan struct{})
	releaseStart := make(chan struct{})

	var eventMu sync.Mutex
	events := []string{}
	record := func(event string) {
		eventMu.Lock()
		events = append(events, event)
		eventMu.Unlock()
	}
	store := &recordingStateStore{onClose: func() { record("store") }}
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error {
			close(enteredStart)
			<-releaseStart
			return nil
		},
		func(*tsnet.Server) (*local.Client, error) {
			return nil, errors.New("LocalClient called for an abandoned startup")
		},
		func(*tsnet.Server) error {
			record("server")
			return nil
		},
	)

	startDone := make(chan error, 1)
	go func() {
		_, _, err := startRuntimeWithDependenciesForTokenAndDeadline(
			token,
			"node",
			"",
			"https://control/",
			stateDir,
			false,
			"",
			deps,
			time.Time{},
		)
		startDone <- err
	}()
	select {
	case <-enteredStart:
	case startErr := <-startDone:
		t.Fatalf("startup returned before entering Server.Start: %v", startErr)
	}

	result, err := AbandonRuntime(token)
	if err != nil {
		t.Fatalf("AbandonRuntime: %v", err)
	}
	if !result.Matched || !result.Pending || result.Started {
		t.Fatalf("abandon result = %+v, want matched pending candidate", result)
	}
	eventMu.Lock()
	if len(events) != 0 {
		t.Fatalf("abandon closed Server.Start concurrently: events=%v", events)
	}
	eventMu.Unlock()
	if _, _, reserveErr := runtimes.reserve(71002, runtimeConfig{}); !errors.Is(reserveErr, ErrLifecycleBusy) {
		t.Fatalf("replacement reserve during quarantine = %v, want lifecycle busy", reserveErr)
	}

	close(releaseStart)
	if startErr := <-startDone; !errors.Is(startErr, ErrStartupAbandoned) {
		t.Fatalf("late startup error = %v, want ErrStartupAbandoned", startErr)
	}
	if err := AwaitRuntimeQuiescence(token); err != nil {
		t.Fatalf("AwaitRuntimeQuiescence: %v", err)
	}
	if currentRuntime() != nil {
		t.Fatal("abandoned late success became current")
	}
	eventMu.Lock()
	defer eventMu.Unlock()
	if got := fmt.Sprint(events); got != "[server store]" {
		t.Fatalf("late-success close order = %s, want [server store]", got)
	}
}

func TestRuntimeConstruction_AbandonedStartFailureNeverClosesServer(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	const token uint64 = 71003
	enteredStart := make(chan struct{})
	releaseStart := make(chan struct{})
	startFailure := errors.New("injected late Start failure")
	store := new(recordingStateStore)
	var serverCloseCalls atomic.Int32
	deps := constructionDependencies(
		store,
		func(*tsnet.Server) error {
			close(enteredStart)
			<-releaseStart
			return startFailure
		},
		func(*tsnet.Server) (*local.Client, error) {
			return nil, errors.New("LocalClient called after Start failure")
		},
		func(*tsnet.Server) error {
			serverCloseCalls.Add(1)
			return nil
		},
	)

	startDone := make(chan error, 1)
	go func() {
		_, _, err := startRuntimeWithDependenciesForTokenAndDeadline(
			token,
			"node",
			"",
			"https://control/",
			stateDir,
			false,
			"",
			deps,
			time.Time{},
		)
		startDone <- err
	}()
	select {
	case <-enteredStart:
	case startErr := <-startDone:
		t.Fatalf("startup returned before entering Server.Start: %v", startErr)
	}
	result, err := AbandonRuntime(token)
	if err != nil || !result.Pending {
		t.Fatalf("AbandonRuntime = (%+v, %v), want pending", result, err)
	}
	close(releaseStart)
	if startErr := <-startDone; !errors.Is(startErr, startFailure) {
		t.Fatalf("late startup error = %v, want injected failure", startErr)
	}
	if err := AwaitRuntimeQuiescence(token); err != nil {
		t.Fatalf("AwaitRuntimeQuiescence cleanup error = %v, want nil", err)
	}
	if got := serverCloseCalls.Load(); got != 0 {
		t.Fatalf("Server.Close calls = %d after Start failure, want 0", got)
	}
	if got := store.closeCalls.Load(); got != 1 {
		t.Fatalf("Store.Close calls = %d after Start failure, want 1", got)
	}
}

func TestRuntimeConstruction_QuiescenceReportsLateCloseFailure(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	const token uint64 = 71004
	enteredStart := make(chan struct{})
	releaseStart := make(chan struct{})
	closeFailure := errors.New("injected late close failure")
	deps := constructionDependencies(
		new(recordingStateStore),
		func(*tsnet.Server) error {
			close(enteredStart)
			<-releaseStart
			return nil
		},
		func(*tsnet.Server) (*local.Client, error) {
			return nil, errors.New("LocalClient called for abandoned startup")
		},
		func(*tsnet.Server) error { return closeFailure },
	)

	startDone := make(chan error, 1)
	go func() {
		_, _, err := startRuntimeWithDependenciesForTokenAndDeadline(
			token,
			"node",
			"",
			"https://control/",
			stateDir,
			false,
			"",
			deps,
			time.Time{},
		)
		startDone <- err
	}()
	select {
	case <-enteredStart:
	case startErr := <-startDone:
		t.Fatalf("startup returned before entering Server.Start: %v", startErr)
	}
	if result, err := AbandonRuntime(token); err != nil || !result.Pending {
		t.Fatalf("AbandonRuntime = (%+v, %v), want pending", result, err)
	}
	close(releaseStart)
	startErr := <-startDone
	if !errors.Is(startErr, ErrStartupAbandoned) || !errors.Is(startErr, closeFailure) {
		t.Fatalf("late startup error = %v, want abandonment plus close failure", startErr)
	}
	if err := AwaitRuntimeQuiescence(token); !errors.Is(err, closeFailure) {
		t.Fatalf("quiescence error = %v, want close failure", err)
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
	if _, err := StartRuntime("local-client-trust", "test-auth-key", "", true); err != nil {
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
					if got := os.Getenv("TS_LOGS_DIR"); got != filepath.Join(stateDir, "tsnet") {
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

func TestRuntimeConstruction_TightensExistingRuntimeDirectory(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	logDir := filepath.Join(stateDir, "tsnet")
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
	for _, component := range []string{"tailscale", "tsnet"} {
		t.Run(component, func(t *testing.T) {
			stateDir := configureFreshStateRootForTest(t)
			if component == "tsnet" {
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
			if component == "tsnet" {
				link = filepath.Join(stateDir, "tsnet")
			}
			if err := os.Symlink(target, link); err != nil {
				t.Skipf("symlinks unavailable: %v", err)
			}

			deps := constructionDependencies(
				new(recordingStateStore),
				func(*tsnet.Server) error { return nil },
				func(*tsnet.Server) (*local.Client, error) { return &local.Client{}, nil },
				func(*tsnet.Server) error { return nil },
			)
			if _, err := startRuntimeWithDependencies("node", "", "", stateDir, false, "", deps); err == nil {
				t.Fatal("start accepted a symlinked package-owned directory")
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
			if _, err := os.Stat(filepath.Join(target, "tsnet")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("external target gained package runtime directory: %v", err)
			}
		})
	}
}

func TestRuntimeConstruction_RejectsWrongTypeOwnedDirectoriesBeforeStoreOpen(t *testing.T) {
	for _, component := range []string{"tailscale", "tsnet"} {
		t.Run(component, func(t *testing.T) {
			stateDir := configureFreshStateRootForTest(t)
			path := stateDir
			if component == "tsnet" {
				if err := os.Mkdir(stateDir, 0o700); err != nil {
					t.Fatal(err)
				}
				path = filepath.Join(stateDir, "tsnet")
			}
			if err := os.WriteFile(path, []byte("not a directory"), 0o600); err != nil {
				t.Fatal(err)
			}

			deps := constructionDependencies(
				new(recordingStateStore),
				func(*tsnet.Server) error { return nil },
				func(*tsnet.Server) (*local.Client, error) { return &local.Client{}, nil },
				func(*tsnet.Server) error { return nil },
			)
			if _, err := startRuntimeWithDependencies("node", "", "", stateDir, false, "", deps); err == nil {
				t.Fatal("start accepted a non-directory package-owned path")
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
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
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
