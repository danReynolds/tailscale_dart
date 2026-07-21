package tailscale

import (
	"sync/atomic"

	"tailscale.com/tsnet"
)

// nodeEpoch identifies the current node lifecycle. stopLocked increments it —
// under mu, BEFORE sweeping any registry — every time a node is torn down, so
// each Start..Stop span has a distinct value. Written only while holding mu;
// read lock-free anywhere via atomic load.
//
// This is the process-wide guard against the teardown registration race: since
// slow operations (serve/funnel forward, dial, HTTP requests) moved off the
// serial worker isolate, they can be in flight while Stop tears the node down,
// and a result committed into a process-global registry after that registry's
// teardown sweep would outlive the node (a persisted serve mount that
// re-exposes on the next Start, a forwarder on a dead listener, a cached dead
// server). Every such op snapshots a nodeGate at entry and re-checks it at its
// commit point, under the destination registry's own lock:
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
// Why it's airtight: stopLocked bumps the epoch and then sweeps each registry
// under that registry's lock, and the commit checks the epoch under the same
// lock — so for any one registry the commit and the sweep are totally ordered.
// Commit first: the sweep sees the entry and removes it. Sweep first: the
// bump happened-before the sweep's lock release, so the commit's lock acquire
// observes the bumped epoch and refuses. There is no third interleaving.
//
// Why an epoch and not a pointer compare or a boolean latch:
//   - `srv == s` requires mu, and taking mu inside a registry lock would invert
//     the mu → registryMu order — so a pointer check can only run BEFORE the
//     registry lock, leaving a check-to-commit window (the TOCTOU class fixed
//     piecemeal in 0.6.0). The atomic epoch is readable under any lock.
//   - A boolean "stopping" latch must be cleared by the next Start, so an op
//     stuck across TWO lifecycles (gated under node N, N stops, N+1 starts and
//     clears the latch) would pass the check and commit N-era state into N+1's
//     world. Epochs distinguish "my lifecycle" from "any later lifecycle".
var nodeEpoch atomic.Uint64

// nodeGate is an operation's entry-time snapshot of the node it is working
// against: the server to use for the work and the epoch to re-check at commit.
type nodeGate struct {
	s     *tsnet.Server
	epoch uint64
}

// acquireNodeGate snapshots the live server and current epoch. Returns ok=false
// when no node is running (callers keep their existing "called before Start"
// error text).
func acquireNodeGate() (nodeGate, bool) {
	mu.Lock()
	defer mu.Unlock()
	if srv == nil {
		return nodeGate{}, false
	}
	return nodeGate{s: srv, epoch: nodeEpoch.Load()}, true
}

// stillCurrent reports whether the gated lifecycle is still the live one. Safe
// to call under any registry lock (lock-free atomic load; never touches mu).
// Callers must hold the destination registry's lock from this check through
// the registration itself — the check is only meaningful as part of that
// critical section.
func (g nodeGate) stillCurrent() bool {
	return nodeEpoch.Load() == g.epoch
}

// nodeStateSnapshot is a point-in-time census of every process-global registry,
// for tests and leak diagnostics.
type nodeStateSnapshot struct {
	Epoch             uint64
	ServePublications int
	FunnelForwarders  int
	HttpBindings      int
	TcpListeners      int
	UdpBridges        int
	TransportCached   bool
}

// debugNodeState reports the current epoch and per-registry live counts. Each
// count is read under its own lock; the snapshot as a whole is not atomic
// across registries (fine for its diagnostic purpose).
func debugNodeState() nodeStateSnapshot {
	snap := nodeStateSnapshot{Epoch: nodeEpoch.Load()}

	servePublicationMu.Lock()
	snap.ServePublications = len(servePublications)
	servePublicationMu.Unlock()

	funnelMu.Lock()
	snap.FunnelForwarders = len(funnelForwarders)
	funnelMu.Unlock()

	httpBindingMu.Lock()
	snap.HttpBindings = len(httpBindingRegistry)
	httpBindingMu.Unlock()

	tcpFdListenerMu.Lock()
	snap.TcpListeners = len(tcpFdListenerRegistry)
	tcpFdListenerMu.Unlock()

	udpFdBindingMu.Lock()
	snap.UdpBridges = len(udpFdBindingRegistry)
	udpFdBindingMu.Unlock()

	tailnetHTTPTransports.mu.Lock()
	snap.TransportCached = tailnetHTTPTransports.transport != nil
	tailnetHTTPTransports.mu.Unlock()

	return snap
}
