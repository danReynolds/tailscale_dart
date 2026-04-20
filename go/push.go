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

	// watchMu guards watchCancel + publishTimer. StartWatch /
	// StopWatch are normally called serially from the Dart worker
	// isolate, but the mutex keeps the invariant explicit so a
	// future caller can't race us into a double-free on the
	// cancel func.
	watchMu      sync.Mutex
	watchCancel  context.CancelFunc
	publishTimer *time.Timer
)

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
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return
	}

	lc, err := s.LocalClient()
	if err != nil {
		postMessage(map[string]any{
			"type":  "error",
			"code":  "localClient",
			"error": err.Error(),
		})
		return
	}

	ctx, cancel := context.WithCancel(context.Background())

	// Cancel any previous watcher.
	watchMu.Lock()
	if watchCancel != nil {
		watchCancel()
	}
	watchCancel = cancel
	watchMu.Unlock()

	watcher, err := lc.WatchIPNBus(ctx,
		ipn.NotifyInitialState|ipn.NotifyInitialNetMap)
	if err != nil {
		postMessage(map[string]any{
			"type":  "error",
			"code":  "watcher",
			"error": err.Error(),
		})
		cancel()
		return
	}

	go func() {
		defer watcher.Close()
		for {
			n, err := watcher.Next()
			if err != nil {
				// Context cancelled = normal shutdown, don't report.
				if ctx.Err() == nil {
					postMessage(map[string]any{
						"type":  "error",
						"code":  "watcher",
						"error": err.Error(),
					})
				}
				return
			}

			if n.State != nil {
				postMessage(map[string]any{
					"type":  "status",
					"state": n.State.String(),
				})
			}
			if n.ErrMessage != nil {
				postMessage(map[string]any{
					"type":  "error",
					"code":  "node",
					"error": *n.ErrMessage,
				})
			}
			if n.NetMap != nil {
				schedulePeerPublish(ctx, lc)
			}
		}
	}()
}

// schedulePeerPublish debounces publishPeerSnapshot so a burst of
// NetMap deltas (endpoint reshuffles, relay flaps, etc.) collapses
// into a single serialize-and-push. Called from the IPN bus watcher
// goroutine on every NetMap tick; only the last tick in a
// peerPublishDebounce-width window actually produces a message.
func schedulePeerPublish(ctx context.Context, lc *local.Client) {
	watchMu.Lock()
	defer watchMu.Unlock()
	if publishTimer != nil {
		publishTimer.Stop()
	}
	publishTimer = time.AfterFunc(peerPublishDebounce, func() {
		// Re-check cancellation: StopWatch may have fired after the
		// timer was armed and before it ran.
		if ctx.Err() != nil {
			return
		}
		publishPeerSnapshot(ctx, lc)
	})
}

// publishPeerSnapshot fetches the current peer list via LocalAPI and
// pushes it to Dart. Dedup/distinct is left to Dart subscribers.
func publishPeerSnapshot(ctx context.Context, lc *local.Client) {
	status, err := lc.Status(ctx)
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
	postMessage(map[string]any{
		"type":  "peers",
		"peers": json.RawMessage(body),
	})
}

// StopWatch cancels the state watcher goroutine and drains any
// pending debounced peer publish.
func StopWatch() {
	watchMu.Lock()
	defer watchMu.Unlock()
	if watchCancel != nil {
		watchCancel()
		watchCancel = nil
	}
	if publishTimer != nil {
		publishTimer.Stop()
		publishTimer = nil
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
