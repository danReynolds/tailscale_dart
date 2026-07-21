# Concurrency model

How the Go layer stays correct now that native calls arrive from more than one
Dart isolate. Read this before adding a lock, a process-global registry, or a
new offloaded call.

## Two execution regimes

Every native call enters the Go layer from one of two places:

1. **The worker isolate (serial FIFO).** Fast local calls (`status`, `prefs`,
   listener setup, …) and the lifecycle calls (`start`, `stop`, `logout`,
   `up`, `down`) run one-at-a-time on a single Dart isolate. Two worker calls
   can never race each other.
2. **Helper isolates (concurrent).** The long, contended calls — `tcp.dial`,
   `diag.ping`, `serve.forward`, `funnel.forward`, plus every HTTP client
   request goroutine — run on short-lived `Isolate.run` helpers (capped at 32,
   see `lib/src/worker/native_offload.dart`). These are concurrent with the
   worker FIFO and with each other.

The consequence: **any offloaded call can race a lifecycle call.** A
`serve.forward` can be mid-flight while `stop()` tears the node down. Code on
these paths cannot assume the node it started with still exists when it
finishes.

## The node epoch (teardown registration gate)

`go/node_gate.go`. A single mechanism closes every "late op commits state
behind teardown's sweep" race:

- `nodeEpoch` (atomic, written only under `mu`) counts lifecycles. `stopLocked`
  increments it **before** sweeping any registry.
- An op that will register durable state (serve mount, funnel forwarder,
  listener, UDP bridge, cached transport) calls `acquireNodeGate()` at entry —
  snapshotting `(srv, epoch)` — does its slow work with no locks held, and
  re-checks `gate.stillCurrent()` **inside the destination registry's lock** at
  the moment it registers.

Why that is airtight, per registry: the teardown bump happens-before the sweep,
and the sweep and the commit both hold the registry's lock, so they are totally
ordered. Commit first → the sweep observes the entry and removes it. Sweep
first → the commit's lock acquire observes the bumped epoch and refuses. There
is no third interleaving.

Two properties make the epoch strictly stronger than its predecessors (a
per-subsystem `srv == s` compare or a boolean "stopping" latch):

- The check is a lock-free atomic load, so it can run under any registry lock
  without touching `mu` — a pointer compare needs `mu`, which would invert the
  lock order, forcing the check *before* the registry lock and leaving a
  check-to-commit window (the 0.6.0 TOCTOU class).
- A latch is cleared by the next `Start`, so an op stuck across two lifecycles
  would pass it and commit old-lifecycle state into the new node's world. An
  epoch compare refuses *any* later lifecycle.

What the epoch does **not** replace: the teardown sweeps themselves
(`closeAll*`), and the mid-lifecycle self-heal reaps (a funnel forwarder or
HTTP binding whose listener dies is reaped by its Serve goroutine). Those
handle resource death; the epoch handles registration ordering.

Adding a new registry? Acquire a gate at op entry, check it at the commit
point under your registry lock, sweep in `stopLocked` (after the bump — i.e.
anywhere in `stopLocked`), and add a row to
`TestCommitGates_RefuseStaleAcrossRegistries` (`go/node_gate_test.go`).

## Lock ordering

One global order; take locks left to right, never right to left:

```
mu  →  serveConfigMu   →  servePublicationMu
mu  →  funnelMu        →  ff.mu (per-forwarder)
mu  →  httpBindingMu | tcpFdListenerMu | udpFdBindingMu
mu  →  tailnetHTTPTransports.mu        (stopLocked's reset path)
watchMu  →  identityCache.mu
reactorMu, dartPortMu, hostNetworkMu, state_store.mu   (leaf, no nesting)
```

Rules that keep it acyclic:

- `mu` is outermost. Nothing acquires `mu` while holding any other package
  lock. (`nodeEpoch` reads exist so commit-point checks never need to.)
- Registry locks never nest with each other; `stopLocked` takes them one at a
  time.
- Calls that can block on the tailnet or the IPN bus (`ListenFunnel`, `Up`,
  dials) run with **no** package lock held; results are committed afterward
  under the registry lock with a gate check. One deliberate exception:
  `serveConfigMu` is held across *loopback LocalAPI* round trips
  (`GetServeConfig`/`SetServeConfig`/`StatusWithoutPeers`) — serializing that
  get-modify-set is the lock's entire purpose, and those are local-socket
  calls, not tailnet waits. Never extend that exception to `mu` or to calls
  that wait on the network.
- `UdpCloseBinding`/`closeAllUdpBindings` invoke a bridge's close callback
  only after releasing `udpFdBindingMu` (the callback re-enters the registry
  to deregister — Go mutexes are not reentrant).

## Diagnostics

`debugNodeState()` (`go/node_gate.go`) reports the epoch and live counts for
every registry. Today it is test-facing only (not exported over FFI); when
hunting a leak across up/down cycles, call it from a Go test or a temporary
probe. Wiring it into a user-reachable diagnostics surface is planned 0.7
tail work.
