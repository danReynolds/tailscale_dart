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
	"unsafe"

	"tailscale.com/ipn"
)

var (
	dartPort    C.Dart_Port_DL
	dartPortMu  sync.Mutex
	watchCancel context.CancelFunc
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
	if watchCancel != nil {
		watchCancel()
	}
	watchCancel = cancel

	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
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

			msg := map[string]any{"type": "status"}
			changed := false

			if n.State != nil {
				msg["state"] = n.State.String()
				changed = true
			}
			if n.ErrMessage != nil {
				msg["type"] = "error"
				msg["code"] = "node"
				msg["error"] = *n.ErrMessage
				changed = true
			}

			if changed {
				postMessage(msg)
			}
		}
	}()
}

// StopWatch cancels the state watcher goroutine.
func StopWatch() {
	if watchCancel != nil {
		watchCancel()
		watchCancel = nil
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
