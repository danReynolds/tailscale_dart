package tailscale

/*
#cgo CFLAGS: -I${SRCDIR}/native -I${SRCDIR}/native/dart
#include <stdlib.h>
#include "native/dart_push.h"
#include "native/dart/dart_api_dl.c"
#include "native/dart_push.c"
*/
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

// peerPublishDebounce coalesces rapid NetMap deltas into a single
// Dart-bound publish. Endpoint changes, relay flaps, and hostinfo
// updates can fire several NetMap events in a burst; without this,
// we'd serialize + push the full peer list for each one.
const peerPublishDebounce = 100 * time.Millisecond

var (
	dartPort   C.Dart_Port_DL
	dartPortMu sync.Mutex

	// watchMu is the watcher publication barrier. A watcher must be both the
	// active owner and from the current runtime generation while holding this
	// lock to publish into Dart or replace the identity cache. StopWatch clears
	// ownership under the same lock, then joins the watcher and timer callbacks.
	watchMu     sync.Mutex
	activeWatch *watcherRun
)

type watcherRun struct {
	generation   uint64
	runtimeToken uint64
	ctx          context.Context
	cancel       context.CancelFunc
	done         chan struct{}
	doneOnce     sync.Once
	publishWG    sync.WaitGroup
	timer        *time.Timer // guarded by watchMu
	post         func(map[string]any)
}

// watchState retains the fail-safe branch's test and receipt vocabulary while
// watcherRun remains the generation-oriented implementation name.
type watchState = watcherRun

func (run *watcherRun) finish() {
	run.doneOnce.Do(func() { close(run.done) })
}

func watcherRunCurrentLocked(run *watcherRun) bool {
	return run != nil &&
		activeWatch == run &&
		run.ctx.Err() == nil &&
		nodeEpoch.Load() == run.generation
}

// postIfCurrent is retained for focused watcher tests. Production watcher
// publications use postWatcherMessage, which also enforces the generation.
func (run *watcherRun) postIfCurrent(message map[string]any) {
	watchMu.Lock()
	defer watchMu.Unlock()
	if activeWatch != run || run.ctx.Err() != nil {
		return
	}
	post := run.post
	if post == nil {
		post = postMessage
	}
	post(message)
}

// InitializeDartAPI must be called once with NativeApi.initializeApiDLData.
func InitializeDartAPI(data unsafe.Pointer) bool {
	return C.dart_push_init(data) == 0
}

// SetDartPort stores the Dart ReceivePort ID for push notifications.
func SetDartPort(port int64) {
	dartPortMu.Lock()
	dartPort = C.Dart_Port_DL(port)
	dartPortMu.Unlock()
}

// StartWatch begins watching tsnet state changes and posting to Dart.
// Must be called after Start() succeeds.
func StartWatch() {
	runtime := currentRuntime()
	if runtime == nil {
		return
	}
	StopWatch()

	lc := runtime.localClient
	ctx, cancel := context.WithCancel(runtime.ctx)
	watcher, err := lc.WatchIPNBus(ctx,
		ipn.NotifyInitialState|ipn.NotifyInitialNetMap)
	if err != nil {
		postRuntimeWatcherMessage(runtime, map[string]any{
			"type":         "error",
			"runtimeToken": runtime.token,
			"code":         "watcher",
			"error":        err.Error(),
		})
		cancel()
		return
	}
	run := &watcherRun{
		generation:   runtime.generation,
		runtimeToken: runtime.token,
		ctx:          ctx,
		cancel:       cancel,
		done:         make(chan struct{}),
		post:         postMessage,
	}

	watchMu.Lock()
	if runtime.validateCurrent() != nil {
		watchMu.Unlock()
		cancel()
		_ = watcher.Close()
		return
	}
	previous := activeWatch
	activeWatch = run
	if previous != nil {
		previous.cancel()
		stopWatcherTimerLocked(previous)
	}
	// A replacement watcher must not inherit an identity index from the old
	// generation while it waits for its initial netmap.
	identityCache.invalidate()
	watchMu.Unlock()

	go func() {
		defer finishWatcherRun(run)
		defer watcher.Close()
		for {
			n, err := watcher.Next()
			if err != nil {
				// A non-cancel error means this watcher is dying while still
				// active. Invalidate the identity index so accept-time lookups
				// fall back to a live WhoIs instead of using a frozen netmap.
				watchMu.Lock()
				current := watcherRunCurrentLocked(run)
				if current {
					identityCache.invalidate()
				}
				watchMu.Unlock()
				// Context cancellation and supersession are normal shutdown.
				if current {
					postWatcherMessage(run, map[string]any{
						"type":         "error",
						"runtimeToken": run.runtimeToken,
						"code":         "watcher",
						"error":        err.Error(),
					})
				}
				return
			}

			if n.State != nil {
				postWatcherMessage(run, map[string]any{
					"type":         "status",
					"runtimeToken": run.runtimeToken,
					"state":        n.State.String(),
				})
			}
			if n.ErrMessage != nil {
				postWatcherMessage(run, map[string]any{
					"type":         "error",
					"runtimeToken": run.runtimeToken,
					"code":         "node",
					"error":        *n.ErrMessage,
				})
			}
			if n.NetMap != nil {
				// Identity must be fresh immediately, while the Dart peer snapshot
				// can be debounced. Build outside the lock and commit only if this
				// watcher still owns the current generation.
				idx := buildIdentityIndex(n.NetMap)
				watchMu.Lock()
				if watcherRunCurrentLocked(run) {
					identityCache.replace(idx)
				}
				watchMu.Unlock()
				schedulePeerPublish(run, lc)
			}
		}
	}()

	// Concurrent replacement is not expected from Dart, but if it occurs,
	// StartWatch does not return while the displaced watcher can still publish.
	if previous != nil {
		<-previous.done
		previous.publishWG.Wait()
	}
}

// schedulePeerPublish debounces publishPeerSnapshot so a burst of NetMap
// deltas collapses into a single serialize-and-push.
func schedulePeerPublish(run *watcherRun, lc *local.Client) {
	watchMu.Lock()
	defer watchMu.Unlock()
	if !watcherRunCurrentLocked(run) {
		return
	}
	scheduleWatcherTimerLocked(run, peerPublishDebounce, func() {
		publishPeerSnapshot(run, lc)
	})
}

// scheduleWatcherTimerLocked replaces a run's pending debounce callback while
// accounting for callbacks that have already fired. Callers must hold watchMu.
func scheduleWatcherTimerLocked(run *watcherRun, delay time.Duration, callback func()) {
	stopWatcherTimerLocked(run)
	run.publishWG.Add(1)
	run.timer = time.AfterFunc(delay, func() {
		defer run.publishWG.Done()
		callback()
	})
}

// stopWatcherTimerLocked releases the callback count itself only when Stop
// proves the callback never started. A false result means it is running or has
// already called Done. Callers must hold watchMu.
func stopWatcherTimerLocked(run *watcherRun) {
	if run == nil || run.timer == nil {
		return
	}
	if run.timer.Stop() {
		run.publishWG.Done()
	}
	run.timer = nil
}

// publishPeerSnapshot fetches the current peer list via LocalAPI and pushes it
// to Dart. The final post is gated again because Status may complete late.
func publishPeerSnapshot(run *watcherRun, lc *local.Client) {
	status, err := lc.Status(run.ctx)
	if err != nil {
		return
	}
	peers := make([]*ipnstate.PeerStatus, 0, len(status.Peer))
	for _, peer := range status.Peer {
		peers = append(peers, peer)
	}
	ipnstate.SortPeers(peers)
	body, err := json.Marshal(peers)
	if err != nil {
		return
	}
	postWatcherMessage(run, map[string]any{
		"type":         "peers",
		"runtimeToken": run.runtimeToken,
		"peers":        json.RawMessage(body),
	})
}

// postWatcherMessage performs the final owner, cancellation, and generation
// check at the Dart boundary. Holding watchMu through the post makes StopWatch
// a publication barrier: after it detaches a run, no delayed result can escape.
func postWatcherMessage(run *watcherRun, msg map[string]any) bool {
	watchMu.Lock()
	defer watchMu.Unlock()
	if !watcherRunCurrentLocked(run) {
		return false
	}
	if _, ok := msg["runtimeToken"]; !ok {
		msg["runtimeToken"] = run.runtimeToken
	}
	post := run.post
	if post == nil {
		post = postMessage
	}
	post(msg)
	return true
}

func postRuntimeWatcherMessage(runtime *nodeRuntime, msg map[string]any) bool {
	watchMu.Lock()
	defer watchMu.Unlock()
	if runtime == nil || runtime.validateCurrent() != nil {
		return false
	}
	if _, ok := msg["runtimeToken"]; !ok {
		msg["runtimeToken"] = runtime.token
	}
	postMessage(msg)
	return true
}

func finishWatcherRun(run *watcherRun) {
	// Abort any LocalAPI request in a fired debounce callback before joining it.
	run.cancel()
	watchMu.Lock()
	if activeWatch == run {
		stopWatcherTimerLocked(run)
		identityCache.invalidate()
	}
	watchMu.Unlock()

	// done covers the complete production watcher lifetime: the IPN loop and
	// every debounce callback that actually began have returned.
	run.publishWG.Wait()

	// Keep a naturally exiting run discoverable until callbacks drain, so a
	// concurrent StopWatch can still join it.
	watchMu.Lock()
	if activeWatch == run {
		activeWatch = nil
	}
	run.finish()
	watchMu.Unlock()
}

// StopWatch cancels the state watcher and joins both its IPN loop and every
// debounce callback that could publish a delayed peer snapshot.
func StopWatch() {
	watchMu.Lock()
	run := activeWatch
	activeWatch = nil
	if run != nil {
		run.cancel()
		stopWatcherTimerLocked(run)
	}
	// Invalidate before releasing the barrier so no accept path can consume an
	// old generation's identity index while watcher teardown drains.
	identityCache.invalidate()
	watchMu.Unlock()

	if run == nil {
		return
	}
	<-run.done
	// Real watcher completion already includes this wait; keep it explicit for
	// callers/tests that supply the two completion sources independently.
	run.publishWG.Wait()
}

func postMessage(msg map[string]any) {
	b, err := json.Marshal(msg)
	if err != nil {
		return
	}
	postString(string(b))
}

func postString(s string) {
	dartPortMu.Lock()
	port := dartPort
	dartPortMu.Unlock()
	if port == 0 {
		return
	}

	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	C.dart_push_string(port, cs)
}
