package tailscale

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestStopWatchJoinsSourcesAndDropsDelayedCallbacks(t *testing.T) {
	StopWatch()
	ctx, cancel := context.WithCancel(context.Background())
	var messagesMu sync.Mutex
	var messages []string
	state := &watchState{
		ctx:          ctx,
		cancel:       cancel,
		done:         make(chan struct{}),
		runtimeToken: 73001,
		post: func(message map[string]any) {
			messagesMu.Lock()
			messages = append(messages, message["type"].(string))
			messagesMu.Unlock()
		},
	}
	state.publishWG.Add(1)

	releaseWatcher := make(chan struct{})
	releasePublisher := make(chan struct{})
	watcherCanceled := make(chan struct{})
	publisherCanceled := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(watcherCanceled)
		<-releaseWatcher
		state.postIfCurrent(map[string]any{"type": "status", "runtimeToken": state.runtimeToken})
		state.postIfCurrent(map[string]any{"type": "error", "runtimeToken": state.runtimeToken})
		close(state.done)
	}()
	go func() {
		<-ctx.Done()
		close(publisherCanceled)
		<-releasePublisher
		state.postIfCurrent(map[string]any{"type": "peers", "runtimeToken": state.runtimeToken})
		state.publishWG.Done()
	}()

	watchMu.Lock()
	activeWatch = state
	watchMu.Unlock()
	stopDone := make(chan struct{})
	go func() {
		StopWatch()
		close(stopDone)
	}()

	<-watcherCanceled
	<-publisherCanceled
	select {
	case <-stopDone:
		t.Fatal("StopWatch returned before watcher and publisher joined")
	default:
	}
	close(releaseWatcher)
	select {
	case <-stopDone:
		t.Fatal("StopWatch returned before pending publisher joined")
	default:
	}
	close(releasePublisher)
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("StopWatch did not return after watcher and publisher joined")
	}
	messagesMu.Lock()
	if len(messages) != 0 {
		messagesMu.Unlock()
		t.Fatalf("callbacks crossed teardown boundary: %v", messages)
	}
	messagesMu.Unlock()

	replacementCtx, replacementCancel := context.WithCancel(context.Background())
	replacement := &watchState{
		ctx:          replacementCtx,
		cancel:       replacementCancel,
		done:         make(chan struct{}),
		runtimeToken: 73002,
		post:         state.post,
	}
	close(replacement.done)
	watchMu.Lock()
	activeWatch = replacement
	watchMu.Unlock()
	state.postIfCurrent(map[string]any{"type": "status", "runtimeToken": state.runtimeToken})
	state.postIfCurrent(map[string]any{"type": "error", "runtimeToken": state.runtimeToken})
	state.postIfCurrent(map[string]any{"type": "peers", "runtimeToken": state.runtimeToken})
	replacement.postIfCurrent(map[string]any{"type": "replacement-status", "runtimeToken": replacement.runtimeToken})
	StopWatch()

	messagesMu.Lock()
	defer messagesMu.Unlock()
	if len(messages) != 1 || messages[0] != "replacement-status" {
		t.Fatalf("replacement gate messages = %v, want only replacement-status", messages)
	}
}
