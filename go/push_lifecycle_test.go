package tailscale

import (
	"context"
	"testing"
	"time"
)

func TestWatcherPublicationRejectsSupersededOwnerAndGeneration(t *testing.T) {
	host := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	t.Cleanup(host.cancel)
	t.Cleanup(host.stopWatch)

	epoch := nodeEpoch.Load()
	oldCtx, oldCancel := context.WithCancel(context.Background())
	old := &watcherRun{
		runtime:    host,
		generation: epoch,
		ctx:        oldCtx,
		cancel:     oldCancel,
		done:       make(chan struct{}),
	}
	newCtx, newCancel := context.WithCancel(context.Background())
	current := &watcherRun{
		runtime:    host,
		generation: epoch,
		ctx:        newCtx,
		cancel:     newCancel,
		done:       make(chan struct{}),
	}

	host.watchMu.Lock()
	host.watch = current
	host.watchMu.Unlock()
	if postWatcherMessage(old, map[string]any{"type": "status"}) {
		t.Fatal("superseded watcher published delayed state")
	}
	if postWatcherMessage(old, map[string]any{"type": "peers"}) {
		t.Fatal("superseded watcher published delayed peers")
	}

	wrongGenerationCtx, wrongGenerationCancel := context.WithCancel(context.Background())
	wrongGeneration := &watcherRun{
		runtime:    host,
		generation: epoch + 1,
		ctx:        wrongGenerationCtx,
		cancel:     wrongGenerationCancel,
		done:       make(chan struct{}),
	}
	host.watchMu.Lock()
	host.watch = wrongGeneration
	host.watchMu.Unlock()
	if postWatcherMessage(wrongGeneration, map[string]any{"type": "status"}) {
		t.Fatal("stale-generation watcher published delayed state")
	}
	if postWatcherMessage(wrongGeneration, map[string]any{"type": "peers"}) {
		t.Fatal("stale-generation watcher published delayed peers")
	}

	host.watchMu.Lock()
	host.watch = nil
	host.watchMu.Unlock()
	oldCancel()
	old.finish()
	newCancel()
	current.finish()
	wrongGenerationCancel()
	wrongGeneration.finish()
}

func TestStopWatchJoinsWatcherBeforeReturning(t *testing.T) {
	host := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	t.Cleanup(host.cancel)

	ctx, cancel := context.WithCancel(context.Background())
	run := &watcherRun{
		runtime:    host,
		generation: nodeEpoch.Load(),
		ctx:        ctx,
		cancel:     cancel,
		done:       make(chan struct{}),
	}
	release := make(chan struct{})
	go func() {
		<-ctx.Done()
		<-release
		finishWatcherRun(run)
	}()

	host.watchMu.Lock()
	host.watch = run
	host.watchMu.Unlock()
	stopped := make(chan struct{})
	go func() {
		host.stopWatch()
		close(stopped)
	}()

	<-ctx.Done()
	select {
	case <-stopped:
		t.Fatal("StopWatch returned before watcher completion")
	default:
	}
	close(release)
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("StopWatch did not return after watcher completion")
	}
}

func TestStopWatchJoinsFiredDebounceCallbackBeforeReturning(t *testing.T) {
	host := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	t.Cleanup(host.cancel)

	ctx, cancel := context.WithCancel(context.Background())
	run := &watcherRun{
		runtime:    host,
		generation: nodeEpoch.Load(),
		ctx:        ctx,
		cancel:     cancel,
		done:       make(chan struct{}),
	}
	callbackStarted := make(chan struct{})
	releaseCallback := make(chan struct{})

	host.watchMu.Lock()
	host.watch = run
	scheduleWatcherTimerLocked(run, 0, func() {
		close(callbackStarted)
		<-releaseCallback
	})
	host.watchMu.Unlock()
	<-callbackStarted

	// Stand in for a watcher that exits naturally before StopWatch is called.
	// It must remain discoverable while its already-fired callback drains.
	go func() {
		<-ctx.Done()
		finishWatcherRun(run)
	}()
	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		host.watchMu.Lock()
		timerDraining := run.timer == nil
		stillOwned := host.watch == run
		host.watchMu.Unlock()
		if timerDraining {
			if !stillOwned {
				t.Fatal("naturally exiting watcher became undiscoverable before callback drain")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("watcher did not begin draining its fired callback")
		}
		time.Sleep(time.Millisecond)
	}

	stopped := make(chan struct{})
	go func() {
		host.stopWatch()
		close(stopped)
	}()

	select {
	case <-stopped:
		t.Fatal("StopWatch returned while a fired debounce callback was running")
	default:
	}
	close(releaseCallback)
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("StopWatch did not return after the debounce callback finished")
	}
}
