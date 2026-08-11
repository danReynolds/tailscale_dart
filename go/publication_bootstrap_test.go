package tailscale

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

func newPublicationBootstrapForTest(t *testing.T) (*nodeRuntime, *publicationManager) {
	t.Helper()
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	manager := newPublicationManagerWithClient(runtime, nil)
	runtime.publication = manager
	t.Cleanup(runtime.cancel)
	return runtime, manager
}

func installBootstrapWatcherForTest(
	t *testing.T,
	runtime *nodeRuntime,
	post func(map[string]any),
) *watcherRun {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	run := &watcherRun{
		runtime:      runtime,
		generation:   runtime.generation,
		runtimeToken: runtime.token,
		ctx:          ctx,
		cancel:       cancel,
		done:         make(chan struct{}),
		post:         post,
	}
	runtime.watchMu.Lock()
	runtime.watch = run
	runtime.watchMu.Unlock()
	t.Cleanup(func() {
		runtime.watchMu.Lock()
		if runtime.watch == run {
			runtime.watch = nil
		}
		runtime.watchMu.Unlock()
		cancel()
		run.finish()
	})
	return run
}

func TestPublicationBootstrapPreRunningFailsImmediately(t *testing.T) {
	_, manager := newPublicationBootstrapForTest(t)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- manager.awaitDataPlaneReady(ctx) }()

	select {
	case err := <-result:
		if !errors.Is(err, ErrDataPlaneNotReady) {
			t.Fatalf("awaitDataPlaneReady error = %v, want ErrDataPlaneNotReady", err)
		}
		var notReady *dataPlaneNotReadyError
		if !errors.As(err, &notReady) {
			t.Fatalf("awaitDataPlaneReady error type = %T, want *dataPlaneNotReadyError", err)
		}
		if notReady.state != ipn.Starting {
			t.Fatalf("not-ready state = %v, want %v", notReady.state, ipn.Starting)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("pre-Running readiness call blocked instead of failing immediately")
	}
}

func TestPublicationBootstrapFirstRunningStartsExactlyOneUp(t *testing.T) {
	runtime, manager := newPublicationBootstrapForTest(t)
	var upCalls atomic.Int32
	upStarted := make(chan struct{})
	releaseUp := make(chan struct{})
	manager.bootstrap.up = func(context.Context) error {
		if upCalls.Add(1) == 1 {
			close(upStarted)
		}
		<-releaseUp
		return nil
	}

	var messagesMu sync.Mutex
	var messages []map[string]any
	run := installBootstrapWatcherForTest(t, runtime, func(message map[string]any) {
		messagesMu.Lock()
		messages = append(messages, message)
		messagesMu.Unlock()
	})

	handleWatcherState(run, ipn.Running)
	select {
	case <-upStarted:
	case <-time.After(time.Second):
		t.Fatal("first Running did not start Up")
	}

	for i := 0; i < 8; i++ {
		suppress, repeated := manager.observeState(ipn.Running)
		if !suppress || repeated != nil {
			t.Fatalf("repeated Running %d = suppress %v start %v, want true/nil", i, suppress, repeated)
		}
	}
	if got := upCalls.Load(); got != 1 {
		t.Fatalf("Up calls before release = %d, want 1", got)
	}

	close(releaseUp)
	readyCtx, cancelReady := context.WithTimeout(context.Background(), time.Second)
	defer cancelReady()
	if err := manager.awaitDataPlaneReady(readyCtx); err != nil {
		t.Fatalf("awaitDataPlaneReady after Up = %v", err)
	}
	if got := upCalls.Load(); got != 1 {
		t.Fatalf("Up calls = %d, want exactly 1", got)
	}

	messagesMu.Lock()
	defer messagesMu.Unlock()
	if len(messages) != 2 ||
		messages[0]["type"] != "status" ||
		messages[0]["state"] != ipn.Starting.String() ||
		messages[1]["type"] != "status" ||
		messages[1]["state"] != ipn.Running.String() {
		t.Fatalf("bootstrap publications = %#v, want Starting then Running", messages)
	}
}

func TestPublicationBootstrapDeadlineUsesInitiatingBudgetUntilSettled(t *testing.T) {
	t.Run("initiating Dart up still pending", func(t *testing.T) {
		_, manager := newPublicationBootstrapForTest(t)
		now := time.Now()
		initiatingDeadline := now.Add(4 * time.Second)
		manager.bootstrap.now = func() time.Time { return now }
		manager.beginInitiatingUp(initiatingDeadline)

		_, start := manager.observeState(ipn.Running)
		if start == nil {
			t.Fatal("Running did not create bootstrap start")
		}
		deadline, ok := start.ctx.Deadline()
		if !ok || !deadline.Equal(initiatingDeadline) {
			t.Fatalf("bootstrap deadline = %v, %v; want initiating deadline %v", deadline, ok, initiatingDeadline)
		}
		manager.bootstrap.cancel()
		close(start.done)
	})

	t.Run("Dart up settled before Running", func(t *testing.T) {
		_, manager := newPublicationBootstrapForTest(t)
		now := time.Now()
		manager.bootstrap.now = func() time.Time { return now }
		manager.beginInitiatingUp(now.Add(4 * time.Second))
		manager.markInitiatingUpSettled()

		_, start := manager.observeState(ipn.Running)
		if start == nil {
			t.Fatal("Running did not create bootstrap start")
		}
		deadline, ok := start.ctx.Deadline()
		want := now.Add(publicationBootstrapMaxWait)
		if !ok || !deadline.Equal(want) {
			t.Fatalf("bootstrap deadline = %v, %v; want fresh deadline %v", deadline, ok, want)
		}
		manager.bootstrap.cancel()
		close(start.done)
	})
}

func TestPublicationBootstrapConcurrentWaitersShareResult(t *testing.T) {
	const waiterCount = 24

	t.Run("success", func(t *testing.T) {
		runtime, manager := newPublicationBootstrapForTest(t)
		_, start := manager.observeState(ipn.Running)
		if start == nil {
			t.Fatal("Running did not create bootstrap start")
		}

		results := make(chan error, waiterCount)
		for i := 0; i < waiterCount; i++ {
			go func() { results <- manager.awaitDataPlaneReady(context.Background()) }()
		}

		run := installBootstrapWatcherForTest(t, runtime, func(map[string]any) {})
		if !manager.publishBootstrapSuccess(run) {
			t.Fatal("current watcher could not publish bootstrap success")
		}
		close(start.done)
		for i := 0; i < waiterCount; i++ {
			if err := <-results; err != nil {
				t.Fatalf("waiter %d error = %v, want nil", i, err)
			}
		}
	})

	t.Run("failure", func(t *testing.T) {
		_, manager := newPublicationBootstrapForTest(t)
		_, start := manager.observeState(ipn.Running)
		if start == nil {
			t.Fatal("Running did not create bootstrap start")
		}

		results := make(chan error, waiterCount)
		for i := 0; i < waiterCount; i++ {
			go func() { results <- manager.awaitDataPlaneReady(context.Background()) }()
		}
		failure, claimed := manager.beginBootstrapFailure(errors.New("forced Up failure"))
		if !claimed {
			t.Fatal("bootstrap failure was not claimed")
		}
		manager.finishBootstrapFailure(failure)
		close(start.done)
		for i := 0; i < waiterCount; i++ {
			err := <-results
			if err != failure {
				t.Fatalf("waiter %d error = %v, want shared result %v", i, err, failure)
			}
			if !errors.Is(err, ErrPublicationBootstrapFailure) {
				t.Fatalf("waiter %d error = %v, want ErrPublicationBootstrapFailure", i, err)
			}
		}
	})
}

func TestPublicationBootstrapShutdownCancelsAndJoinsUp(t *testing.T) {
	_, manager := newPublicationBootstrapForTest(t)
	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("Running did not create bootstrap start")
	}

	cancelObserved := make(chan struct{})
	releaseWorker := make(chan struct{})
	go func() {
		<-start.ctx.Done()
		close(cancelObserved)
		<-releaseWorker
		close(start.done)
	}()

	shutdownDone := make(chan struct{})
	go func() {
		manager.shutdownBootstrap(false)
		close(shutdownDone)
	}()
	select {
	case <-cancelObserved:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not cancel the Up context")
	}
	select {
	case <-shutdownDone:
		t.Fatal("shutdown returned before the Up worker joined")
	default:
	}
	close(releaseWorker)
	select {
	case <-shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not return after the Up worker joined")
	}
	if err := manager.awaitDataPlaneReady(context.Background()); !errors.Is(err, ErrRuntimeStale) {
		t.Fatalf("readiness after shutdown = %v, want ErrRuntimeStale", err)
	}
}

func TestPublicationBootstrapMasksRunningUntilSyntheticPublication(t *testing.T) {
	runtime, manager := newPublicationBootstrapForTest(t)
	if got := manager.maskRunningState(ipn.Running.String()); got != ipn.Starting.String() {
		t.Fatalf("pre-bootstrap Running mask = %q, want %q", got, ipn.Starting.String())
	}
	if got := manager.maskRunningState(ipn.NeedsLogin.String()); got != ipn.NeedsLogin.String() {
		t.Fatalf("non-Running state mask = %q, want unchanged", got)
	}

	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("Running did not create bootstrap start")
	}
	if got := manager.maskRunningState(ipn.Running.String()); got != ipn.Starting.String() {
		t.Fatalf("in-progress Running mask = %q, want %q", got, ipn.Starting.String())
	}
	run := installBootstrapWatcherForTest(t, runtime, func(map[string]any) {})
	if !manager.publishBootstrapSuccess(run) {
		t.Fatal("current watcher could not publish bootstrap success")
	}
	close(start.done)
	if got := manager.maskRunningState(ipn.Running.String()); got != ipn.Running.String() {
		t.Fatalf("ready Running mask = %q, want %q", got, ipn.Running.String())
	}
}

func TestPublicationBootstrapPublishesRunningBeforeReleasingWaiters(t *testing.T) {
	runtime, manager := newPublicationBootstrapForTest(t)
	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("Running did not create bootstrap start")
	}

	postStarted := make(chan struct{})
	releasePost := make(chan struct{})
	run := installBootstrapWatcherForTest(t, runtime, func(message map[string]any) {
		if message["type"] != "status" || message["state"] != ipn.Running.String() {
			t.Errorf("synthetic publication = %#v, want Running status", message)
		}
		close(postStarted)
		<-releasePost
	})

	waiterDone := make(chan error, 1)
	go func() { waiterDone <- manager.awaitDataPlaneReady(context.Background()) }()
	publishDone := make(chan bool, 1)
	go func() { publishDone <- manager.publishBootstrapSuccess(run) }()
	select {
	case <-postStarted:
	case <-time.After(time.Second):
		t.Fatal("synthetic Running publication did not start")
	}
	select {
	case err := <-waiterDone:
		t.Fatalf("readiness waiter escaped before Running publication completed: %v", err)
	default:
	}
	close(releasePost)
	select {
	case published := <-publishDone:
		if !published {
			t.Fatal("current watcher did not publish bootstrap success")
		}
	case <-time.After(time.Second):
		t.Fatal("bootstrap success did not finish after publication was released")
	}
	select {
	case err := <-waiterDone:
		if err != nil {
			t.Fatalf("readiness after Running publication = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("readiness waiter was not released after Running publication")
	}
	close(start.done)
}

func TestPublicationBootstrapDoesNotRepublishStaleRunning(t *testing.T) {
	runtime, manager := newPublicationBootstrapForTest(t)
	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("Running did not create bootstrap start")
	}
	if suppress, repeated := manager.observeState(ipn.NeedsLogin); suppress || repeated != nil {
		t.Fatalf("newer NeedsLogin = suppress %v start %v, want false/nil", suppress, repeated)
	}

	var posts atomic.Int32
	run := installBootstrapWatcherForTest(t, runtime, func(map[string]any) { posts.Add(1) })
	if !manager.publishBootstrapSuccess(run) {
		t.Fatal("successful reset did not open bootstrap readiness")
	}
	close(start.done)
	if posts.Load() != 0 {
		t.Fatalf("synthetic Running posts after newer NeedsLogin = %d, want 0", posts.Load())
	}
	if err := manager.awaitDataPlaneReady(context.Background()); err != nil {
		t.Fatalf("successful reset did not release readiness: %v", err)
	}
	if suppress, repeated := manager.observeState(ipn.Running); suppress || repeated != nil {
		t.Fatalf("later real Running = suppress %v start %v, want false/nil", suppress, repeated)
	}
}

func TestPublicationBootstrapRejectsSupersededWatcher(t *testing.T) {
	runtime, manager := newPublicationBootstrapForTest(t)
	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("Running did not create bootstrap start")
	}

	var posts atomic.Int32
	run := installBootstrapWatcherForTest(t, runtime, func(map[string]any) { posts.Add(1) })
	runtime.watchMu.Lock()
	runtime.watch = nil
	runtime.watchMu.Unlock()
	if manager.publishBootstrapSuccess(run) {
		t.Fatal("superseded watcher published bootstrap success")
	}
	if posts.Load() != 0 {
		t.Fatalf("superseded watcher posts = %d, want 0", posts.Load())
	}
	select {
	case <-manager.bootstrap.result:
		t.Fatal("superseded watcher released readiness")
	default:
	}

	failure, claimed := manager.beginBootstrapFailure(errors.New("watcher superseded"))
	if !claimed {
		t.Fatal("lost watcher bootstrap failure was not claimed")
	}
	manager.finishBootstrapFailure(failure)
	close(start.done)
}

func TestPublicationBootstrapFailureReapsExactRuntime(t *testing.T) {
	for _, cleanupFails := range []bool{false, true} {
		name := "clean teardown"
		if cleanupFails {
			name = "cleanup failure poisons admission"
		}
		t.Run(name, func(t *testing.T) {
			runtimes.mu.Lock()
			previousFailure := runtimes.cleanupFailure
			runtimes.cleanupFailure = nil
			runtimes.mu.Unlock()
			t.Cleanup(func() {
				runtimes.mu.Lock()
				runtimes.cleanupFailure = previousFailure
				runtimes.mu.Unlock()
			})

			withLiveServer(t, new(tsnet.Server))
			runtime := currentRuntime()
			manager := newPublicationManagerWithClient(runtime, nil)
			runtime.publication = manager
			closeCalled := make(chan struct{})
			cleanupCause := errors.New("injected Server.Close failure")
			runtime.closeServer = func(*tsnet.Server) error {
				close(closeCalled)
				if cleanupFails {
					return cleanupCause
				}
				return nil
			}

			upCause := errors.New("injected first-Up failure")
			if !failPublicationBootstrap(runtime, upCause) {
				t.Fatal("first bootstrap failure was not claimed")
			}
			select {
			case <-closeCalled:
			case <-time.After(time.Second):
				t.Fatal("fatal bootstrap reaper did not close the exact runtime")
			}

			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err := manager.awaitDataPlaneReady(ctx)
			if !errors.Is(err, ErrPublicationBootstrapFailure) || !errors.Is(err, upCause) {
				t.Fatalf("gate failure = %v, want bootstrap sentinel and original cause", err)
			}
			if cleanupFails {
				if !errors.Is(err, ErrRuntimeCleanupFailed) || !errors.Is(err, cleanupCause) {
					t.Fatalf("gate failure = %v, want cleanup failure evidence", err)
				}
			} else if errors.Is(err, ErrRuntimeCleanupFailed) {
				t.Fatalf("clean teardown reported cleanup failure: %v", err)
			}

			deadline := time.Now().Add(time.Second)
			for {
				runtimes.mu.Lock()
				current := runtimes.current
				draining := runtimes.draining
				admissionErr := runtimes.cleanupAdmissionErrorLocked()
				runtimes.mu.Unlock()
				if current == nil && draining == nil {
					if cleanupFails && !errors.Is(admissionErr, ErrRuntimeCleanupFailed) {
						t.Fatalf("cleanup failure did not block admission: %v", admissionErr)
					}
					if !cleanupFails && admissionErr != nil {
						t.Fatalf("clean teardown blocked admission: %v", admissionErr)
					}
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("fatal reaper did not finish: current=%p draining=%p", current, draining)
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}
