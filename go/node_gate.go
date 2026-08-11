package tailscale

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"

	"tailscale.com/tsnet"
)

// nodeEpoch identifies the current node lifecycle. runtimeController increments
// it, under its lock and before sweeping any registry, every time a node is
// detached. Each Start..Stop span therefore has a distinct value.
//
// This is the process-wide guard against the teardown registration race: since
// slow data-plane operations run outside the serial worker isolate, they can be
// in flight while Stop tears the node down. A result committed after teardown
// could otherwise outlive its node (for example, a listener registered after
// its registry sweep). Every operation snapshots a nodeGate at entry and
// re-checks it at its commit point under the destination owner's lock. R5's
// Serve/Funnel publication manager is itself runtime-owned and performs the
// equivalent check while holding its mutation lock; the remaining registries
// use the pattern below:
//
//	gate, ok := acquireNodeGate()          // at op entry
//	...slow work, no locks held...
//	registryMu.Lock()
//	if !gate.stillCurrent() {              // at commit
//		registryMu.Unlock()
//		cleanup()
//		return errNodeStopped
//	}
//	register(...)
//	registryMu.Unlock()
//
// Why it's airtight: runtimeController bumps the epoch and nodeRuntime.close
// then sweeps each registry under that registry's lock. The commit checks the
// epoch under the same lock, so commit and sweep are totally ordered.
// Commit first: the sweep sees the entry and removes it. Sweep first: the
// bump happened-before the sweep's lock release, so the commit's lock acquire
// observes the bumped epoch and refuses. There is no third interleaving.
//
// Why an epoch and not a pointer compare or a boolean latch:
//   - comparing the controller's current pointer requires its lock, and taking
//     that lock inside a registry lock would invert lock order. The atomic
//     epoch is readable under any lock.
//   - A boolean "stopping" latch must be cleared by the next Start, so an op
//     stuck across TWO lifecycles (gated under node N, N stops, N+1 starts and
//     clears the latch) would pass the check and commit N-era state into N+1's
//     world. Epochs distinguish "my lifecycle" from "any later lifecycle".
var nodeEpoch atomic.Uint64

func init() {
	// Generation zero is reserved as an absent/invalid capability on the FFI
	// wire. Starting at one keeps exact publication-handle equality natural.
	nodeEpoch.Store(1)
}

// nodeGate is an operation's entry-time snapshot of the node it is working
// against: the server to use for the work and the epoch to re-check at commit.
type nodeGate struct {
	runtime *nodeRuntime
	s       *tsnet.Server
	epoch   uint64
}

// gate builds the runtime's own entry-time snapshot. It is the only sanctioned
// way to construct a nodeGate from a runtime already in hand, so a gate can
// never pair a runtime with another generation's epoch.
func (r *nodeRuntime) gate() nodeGate {
	return nodeGate{runtime: r, s: r.server, epoch: r.generation}
}

// acquireNodeGate snapshots the live server and current epoch. Returns ok=false
// when no node is running (callers keep their existing "called before Start"
// error text).
func acquireNodeGate() (nodeGate, bool) {
	runtime := currentRuntime()
	if runtime == nil {
		return nodeGate{}, false
	}
	return nodeGate{
		runtime: runtime,
		s:       runtime.server,
		epoch:   runtime.generation,
	}, true
}

// acquireNodeGateForRuntimeToken admits work only for the exact runtime
// capability captured by Dart before it queued a helper-isolate call. The
// comparison and snapshot happen under the controller lock, so stale work can
// never be redirected to a replacement runtime's Server or LocalClient.
func acquireNodeGateForRuntimeToken(runtimeToken uint64) (nodeGate, bool) {
	if runtimeToken == 0 {
		return nodeGate{}, false
	}
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	runtime := runtimes.current
	if runtime == nil || runtime.token != runtimeToken || runtime.ctx.Err() != nil {
		return nodeGate{}, false
	}
	return nodeGate{
		runtime: runtime,
		s:       runtime.server,
		epoch:   runtime.generation,
	}, true
}

// gateForRuntimeToken admits token-qualified FFI work for the exact current
// runtime and formats the one standard typed stale error otherwise. A zero
// token with no runtime keeps the friendlier before-Start spelling; every
// other refusal names the captured token so logs identify the stale caller.
func gateForRuntimeToken(op string, runtimeToken uint64) (nodeGate, error) {
	gate, ok := acquireNodeGateForRuntimeToken(runtimeToken)
	if ok {
		return gate, nil
	}
	if runtimeToken == 0 && currentRuntime() == nil {
		return nodeGate{}, fmt.Errorf("%w: %s called before Start", ErrRuntimeStale, op)
	}
	return nodeGate{}, fmt.Errorf(
		"%w: %s captured runtime %d is no longer current",
		ErrRuntimeStale,
		op,
		runtimeToken,
	)
}

// stillCurrent reports whether the gated lifecycle is still the live one. Safe
// to call under any registry lock (lock-free atomic load; never touches mu).
// Callers must hold the destination registry's lock from this check through
// the registration itself — the check is only meaningful as part of that
// critical section.
func (g nodeGate) stillCurrent() bool {
	return nodeEpoch.Load() == g.epoch
}

// awaitDataPlaneReady joins the runtime's one bounded first-Up bootstrap, then
// rechecks this exact generation before callers touch Server or LocalAPI.
func (g nodeGate) awaitDataPlaneReady(ctx context.Context) error {
	if g.runtime == nil || g.runtime.publication == nil {
		return ErrRuntimeStale
	}
	if err := g.runtime.publication.awaitDataPlaneReady(ctx); err != nil {
		return err
	}
	if !g.stillCurrent() || g.runtime.ctx.Err() != nil {
		return ErrRuntimeStale
	}
	return nil
}

// awaitDataPlaneReadyForCall applies the standard native-call timeout and
// runtime cancellation to a data-plane readiness wait.
func (g nodeGate) awaitDataPlaneReadyForCall() error {
	if g.runtime == nil {
		return ErrRuntimeStale
	}
	ctx, cancel := boundedCallCtxFrom(g.runtime.ctx, 0)
	defer cancel()
	return g.awaitDataPlaneReady(ctx)
}

// DataPlaneReady reports whether [runtimeToken] still identifies the current
// runtime and that runtime's one first-Up publication bootstrap has succeeded.
// It never blocks or joins the bootstrap: Dart's HTTP send path probes it to
// run the native admission call directly on the caller isolate instead of a
// helper isolate. Readiness is resolved through the exact token, so a
// replacement runtime's un-bootstrapped generation can never inherit a stale
// ready answer; HttpStart still re-checks token and readiness under its own
// gate, making this probe an optimization, never the authority.
func DataPlaneReady(runtimeToken uint64) bool {
	gate, ok := acquireNodeGateForRuntimeToken(runtimeToken)
	return ok && gate.runtime.publication.bootstrapReady()
}

// nodeStateSnapshot is a point-in-time census of the current runtime's owned
// registries, for tests and leak diagnostics. The JSON tags are the FFI
// contract with `Diag.nodeState()` on the Dart side.
type nodeStateSnapshot struct {
	// Funnel is an AllowFunnel bit on the same ServeConfig entry, so there is
	// no separate funnelForwarders registry or diagnostic count.
	Epoch             uint64 `json:"epoch"`
	ServePublications int    `json:"servePublications"`
	HttpBindings      int    `json:"httpBindings"`
	TcpListeners      int    `json:"tcpListeners"`
	UdpBridges        int    `json:"udpBridges"`
	TransportCached   bool   `json:"transportCached"`
}

// DebugNodeState returns the registry census as JSON, for the Dart-side
// diagnostics surface. Always succeeds; see debugNodeState for atomicity
// caveats.
func DebugNodeState() string {
	data, err := json.Marshal(debugNodeState())
	if err != nil {
		return "{}" // unreachable: fixed struct of scalars
	}
	return string(data)
}

// debugNodeState reports the current epoch and per-registry live counts. Each
// count is read under its own lock; the snapshot as a whole is not atomic
// across registries (fine for its diagnostic purpose).
func debugNodeState() nodeStateSnapshot {
	snap := nodeStateSnapshot{Epoch: nodeEpoch.Load()}

	if runtime := currentRuntime(); runtime != nil {
		snap.ServePublications = runtime.publication.count()
		runtime.httpMu.Lock()
		snap.TransportCached = runtime.httpTransport != nil
		runtime.httpMu.Unlock()
		snap.TcpListeners, snap.UdpBridges, snap.HttpBindings = runtime.fd.census()
	}

	return snap
}
