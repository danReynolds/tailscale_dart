package tailscale

import (
	"context"
	"testing"
	"time"
)

func TestWatcherPublicationRejectsSupersededOwnerAndGeneration(t *testing.T) {
	StopWatch()
	t.Cleanup(StopWatch)

	epoch := nodeEpoch.Load()
	oldCtx, oldCancel := context.WithCancel(context.Background())
	old := &watcherRun{
		generation: epoch,
		ctx:        oldCtx,
		cancel:     oldCancel,
		done:       make(chan struct{}),
	}
	newCtx, newCancel := context.WithCancel(context.Background())
	current := &watcherRun{
		generation: epoch,
		ctx:        newCtx,
		cancel:     newCancel,
		done:       make(chan struct{}),
	}

	watchMu.Lock()
	activeWatch = current
	watchMu.Unlock()
	if postWatcherMessage(old, map[string]any{"type": "status"}) {
		t.Fatal("superseded watcher published delayed state")
	}
	if postWatcherMessage(old, map[string]any{"type": "peers"}) {
		t.Fatal("superseded watcher published delayed peers")
	}

	wrongGenerationCtx, wrongGenerationCancel := context.WithCancel(context.Background())
	wrongGeneration := &watcherRun{
		generation: epoch + 1,
		ctx:        wrongGenerationCtx,
		cancel:     wrongGenerationCancel,
		done:       make(chan struct{}),
	}
	watchMu.Lock()
	activeWatch = wrongGeneration
	watchMu.Unlock()
	if postWatcherMessage(wrongGeneration, map[string]any{"type": "status"}) {
		t.Fatal("stale-generation watcher published delayed state")
	}
	if postWatcherMessage(wrongGeneration, map[string]any{"type": "peers"}) {
		t.Fatal("stale-generation watcher published delayed peers")
	}

	watchMu.Lock()
	activeWatch = nil
	watchMu.Unlock()
	oldCancel()
	old.finish()
	newCancel()
	current.finish()
	wrongGenerationCancel()
	wrongGeneration.finish()
}

func TestStopWatchJoinsWatcherBeforeReturning(t *testing.T) {
	StopWatch()

	ctx, cancel := context.WithCancel(context.Background())
	run := &watcherRun{
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

	watchMu.Lock()
	activeWatch = run
	watchMu.Unlock()
	stopped := make(chan struct{})
	go func() {
		StopWatch()
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
	StopWatch()

	ctx, cancel := context.WithCancel(context.Background())
	run := &watcherRun{
		generation: nodeEpoch.Load(),
		ctx:        ctx,
		cancel:     cancel,
		done:       make(chan struct{}),
	}
	callbackStarted := make(chan struct{})
	releaseCallback := make(chan struct{})

	watchMu.Lock()
	activeWatch = run
	scheduleWatcherTimerLocked(run, 0, func() {
		close(callbackStarted)
		<-releaseCallback
	})
	watchMu.Unlock()
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
		watchMu.Lock()
		timerDraining := run.timer == nil
		stillOwned := activeWatch == run
		watchMu.Unlock()
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
		StopWatch()
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
