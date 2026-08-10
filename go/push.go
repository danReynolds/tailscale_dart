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
	// ownership under the same lock, then joins the watcher outside it.
	watchMu     sync.Mutex
	activeWatch *watcherRun
)

type watcherRun struct {
	generation uint64
	ctx        context.Context
	cancel     context.CancelFunc
	done       chan struct{}
	doneOnce   sync.Once
	callbacks  sync.WaitGroup
	timer      *time.Timer // guarded by watchMu
}

func (run *watcherRun) finish() {
	run.doneOnce.Do(func() { close(run.done) })
}

func watcherRunCurrentLocked(run *watcherRun) bool {
	return run != nil &&
		activeWatch == run &&
		run.ctx.Err() == nil &&
		nodeEpoch.Load() == run.generation
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
	lc := runtime.localClient
	ctx, cancel := context.WithCancel(runtime.ctx)

	watcher, err := lc.WatchIPNBus(ctx,
		ipn.NotifyInitialState|ipn.NotifyInitialNetMap)
	if err != nil {
		postRuntimeWatcherMessage(runtime, map[string]any{
			"type":  "error",
			"code":  "watcher",
			"error": err.Error(),
		})
		cancel()
		return
	}
	run := &watcherRun{
		generation: runtime.generation,
		ctx:        ctx,
		cancel:     cancel,
		done:       make(chan struct{}),
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
				// active (IPN-bus stream/decode error, tailscaled dropping a
				// lagging watcher). Nothing re-arms the watch, so a frozen
				// identity index would drift from the live netmap and — worst
				// case — misattribute a reassigned tailnet address to the old
				// node on the accept path. Drop it so accept-time lookups fall
				// back to a live WhoIs. Gate on ctx like the replace path below
				// so a StopWatch/newer StartWatch that already superseded us
				// keeps ownership of the cache lifecycle (it invalidates or
				// re-warms on its own).
				watchMu.Lock()
				current := watcherRunCurrentLocked(run)
				if current {
					identityCache.invalidate()
				}
				watchMu.Unlock()
				// Context cancelled = normal shutdown, don't report.
				if current {
					postWatcherMessage(run, map[string]any{
						"type":  "error",
						"code":  "watcher",
						"error": err.Error(),
					})
				}
				return
			}

			if n.State != nil {
				postWatcherMessage(run, map[string]any{
					"type":  "status",
					"state": n.State.String(),
				})
			}
			if n.ErrMessage != nil {
				postWatcherMessage(run, map[string]any{
					"type":  "error",
					"code":  "node",
					"error": *n.ErrMessage,
				})
			}
			if n.NetMap != nil {
				// Mirror the netmap into the accept-path identity cache before
				// the debounced peer publish: identity must be fresh the moment
				// a connection is accepted, whereas the Dart peer snapshot can
				// coalesce. Build outside watchMu, then apply only while this
				// watcher's ctx is live. StopWatch cancels ctx and invalidates
				// under watchMu, so gating the swap the same way stops an
				// in-flight tick from re-warming a torn-down cache.
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

	// Replacing a watcher is rare, but make ownership exact: when StartWatch
	// returns there is only one live watcher capable of touching package state.
	if previous != nil {
		<-previous.done
	}
}

// schedulePeerPublish debounces publishPeerSnapshot so a burst of
// NetMap deltas (endpoint reshuffles, relay flaps, etc.) collapses
// into a single serialize-and-push. Called from the IPN bus watcher
// goroutine on every NetMap tick; only the last tick in a
// peerPublishDebounce-width window actually produces a message.
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
// accounting for callbacks that have already fired. Callers must hold watchMu
// and must have established that run is the active owner.
func scheduleWatcherTimerLocked(run *watcherRun, delay time.Duration, callback func()) {
	stopWatcherTimerLocked(run)
	run.callbacks.Add(1)
	run.timer = time.AfterFunc(delay, func() {
		defer run.callbacks.Done()
		callback()
	})
}

// stopWatcherTimerLocked releases the callback count itself only when Stop
// proves the callback never started. A false result means the callback either
// is running or already called Done. Callers must hold watchMu.
func stopWatcherTimerLocked(run *watcherRun) {
	if run == nil || run.timer == nil {
		return
	}
	if run.timer.Stop() {
		run.callbacks.Done()
	}
	run.timer = nil
}

// publishPeerSnapshot fetches the current peer list via LocalAPI and
// pushes it to Dart. Dedup/distinct is left to Dart subscribers.
func publishPeerSnapshot(run *watcherRun, lc *local.Client) {
	status, err := lc.Status(run.ctx)
	if err != nil {
		// Non-fatal — the app will pick up the next NetMap tick.
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
		"type":  "peers",
		"peers": json.RawMessage(body),
	})
}

// postWatcherMessage performs the final ownership check at the Dart boundary.
// Holding watchMu through the post makes StopWatch a publication barrier: once
// it clears activeWatch, no delayed state, error, or peer result can escape.
func postWatcherMessage(run *watcherRun, msg map[string]any) bool {
	watchMu.Lock()
	defer watchMu.Unlock()
	if !watcherRunCurrentLocked(run) {
		return false
	}
	postMessage(msg)
	return true
}

func postRuntimeWatcherMessage(runtime *nodeRuntime, msg map[string]any) bool {
	watchMu.Lock()
	defer watchMu.Unlock()
	if runtime == nil || runtime.validateCurrent() != nil {
		return false
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

	// done is the complete watcher lifetime: both the IPN bus loop and every
	// debounce callback that actually began have returned.
	run.callbacks.Wait()

	// Keep a naturally exiting run discoverable until its callbacks drain, so
	// a concurrent StopWatch can still join it. Close done while transferring
	// ownership under the same barrier: StopWatch then either observes this run
	// and waits for done, or observes no run only after the full drain finished.
	watchMu.Lock()
	if activeWatch == run {
		activeWatch = nil
	}
	run.finish()
	watchMu.Unlock()
}

// StopWatch cancels the state watcher goroutine and drains any
// pending debounced peer publish.
func StopWatch() {
	watchMu.Lock()
	run := activeWatch
	activeWatch = nil
	if run != nil {
		run.cancel()
		stopWatcherTimerLocked(run)
	}
	watchMu.Unlock()

	if run != nil {
		<-run.done
	}

	watchMu.Lock()
	defer watchMu.Unlock()
	// Once we stop receiving netmap ticks the cache can drift from the live
	// netmap; mark it cold so accept-time lookups fall back to a live WhoIs. A
	// concurrently installed successor owns its own freshly invalidated cache.
	if activeWatch == nil {
		identityCache.invalidate()
	}
}

// publishState posts a synthetic state-change event to Dart subscribers.
//
// Used by lib.go's Stop() and Logout() to notify subscribers that the engine
// has transitioned to Stopped / NoState respectively. tsnet.Server.Close()
// doesn't emit a terminal state through the IPN bus — WatchIPNBus just sees
// an error and the goroutine exits silently — so without this, callers that
// mirror state via onStateChange (e.g. the Dart TailscaleClient) get stuck
// at the pre-stop value (usually `Running`) and their UI routing goes
// stale.
//
// `state` must be one of the strings accepted by NodeState.parse on the Dart
// side ("NoState", "NeedsLogin", "NeedsMachineAuth", "Starting", "Running",
// "Stopped").
func publishState(state string) {
	postMessage(map[string]any{
		"type":  "status",
		"state": state,
	})
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
