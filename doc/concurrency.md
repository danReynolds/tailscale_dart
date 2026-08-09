# Concurrency model

How the Go layer stays correct now that native calls arrive from more than one
Dart isolate. Read this before adding a lock, a process-global registry, or a
new offloaded call.

> **Current-state document.** The epoch and commit-gate invariants remain part
> of the target, but process-global resource ownership will move incrementally
> onto `nodeRuntime`. See the [rearchitecture plan](rearchitecture-plan.md) and
> [runtime lifecycle ADR](adr-runtime-ownership-and-lifecycle.md). Update this
> file in each ownership-migration PR so it continues to describe `main`.

## Two execution regimes

Every native call enters the Go layer from one of two places:

1. **The supervised worker isolate (serial FIFO).** Fast local calls (`status`, `prefs`,
   listener setup, …) and the lifecycle calls (`start`, `stop`, `logout`,
   `up`, `down`) run one-at-a-time on a single Dart isolate. Two worker calls
   can never race each other. Lifecycle intent is also reserved in a
   supervisor-side FIFO before Android's asynchronous network snapshot, so an
   earlier `up()` cannot be overtaken by a later `down()` or `logout()` before
   its command reaches the worker. The caller isolate owns a replaceable worker
   instance; public calls resolve that instance at call time rather than
   retaining method tear-offs from a dead isolate.
2. **Helper isolates (concurrent).** The long, contended calls — `tcp.dial`,
   `diag.ping`, `serve.forward`, `funnel.forward`, plus every HTTP client
   request goroutine — run on short-lived `Isolate.run` helpers (capped at 32,
   see `lib/src/worker/native_offload.dart`). These are concurrent with the
   worker FIFO and with each other.

The consequence: **any offloaded call can race a lifecycle call.** A
`serve.forward` can be mid-flight while `stop()` tears the node down. Code on
these paths cannot assume the node it started with still exists when it
finishes.

## Supervisor tokens and fail-safe teardown

The caller isolate creates a unique runtime token before any asynchronous
startup preparation and carries it through the worker into Go. The native
`runtimeController` binds that exact token to one candidate/current/draining
generation. An abandoned token is retired even when timeout happens before the
worker reaches native code, so delayed preparation cannot later reuse it.

`up(timeout:)` establishes token-qualified quarantine before returning a
`startupTimeout` error. If non-cancellable `tsnet.Server.Start` is still
running, native code marks its candidate abandoned and does **not** call
`Server.Close` concurrently. The construction path observes abandonment when
`Start` returns: late success closes Server then Store; failure closes only the
caller-owned Store. Another lifecycle waits for that cleanup barrier.

Every worker exit invokes the event-silent rescue entry point from a helper
isolate. Pending worker RPCs fail promptly with `workerTerminated`; rescue
closes only the captured token, joins native cleanup, classifies idle state,
and only then permits worker replacement. Unexpected exit emits one `worker`
incident followed by truthful terminal state. An exact expected-exit tag
suppresses only that duplicate incident, not rescue or state reconciliation.

Completed `down`/`logout` results are retained natively by token until the
caller isolate acknowledges receipt. That acknowledgement is a tiny in-memory
map deletion (no filesystem, network, or Tailscale work) and is the only native
call made on the caller isolate. If the worker exits after native completion
but before delivery, rescue consumes the retained result instead: cleanup
errors cannot be swallowed and a confirmed logout cannot be mislabeled as
indeterminate.

A failed Server close, Store close, startup unwind, or confirmed-logout state
removal poisons lifecycle admission for the rest of the process with
`runtimeCleanupFailed`. Detachment is not reported as a clean `stopped`
transition unless quiescence was proved. This intentionally requires process
restart instead of opening a replacement over unknown resources or partially
removed state. R4 replaces the process-local partial-removal guard with the
durable encrypted-store reset marker.

Native status, error, and peer pushes carry their runtime token. Dart drops a
push that is not owned by the worker's current/preparing token. `StopWatch`
cancels and joins both the IPN watcher and any in-flight debounced peer publish
before teardown completes, so a replacement port cannot race an old source.

Logout is remote-first. It reconstructs a temporary runtime from persisted
state after `down()`, asks upstream to revoke, and deletes local state only
after confirmed success. Failure or timeout closes the possibly-mutated
runtime, retains recovery evidence, and returns `logoutIndeterminate`.
Starting a fresh candidate first invalidates the cached reopen tuple; only a
successful `Server.Start` records the exact hostname, control URL, and
ephemeral setting it proved it applied. An abandoned late success therefore
remains safely revocable, while an unproven failed attempt cannot make logout
reuse an older control plane.

## The node epoch (teardown registration gate)

`go/node_gate.go`. A single mechanism closes every "late op commits state
behind teardown's sweep" race:

- `nodeEpoch` (atomic, written only under `runtimeController.mu`) counts
  lifecycles. The controller increments it **before** `nodeRuntime.close`
  sweeps any registry.
- An op that will register durable state (serve mount, funnel forwarder,
  listener, UDP bridge, cached transport) calls `acquireNodeGate()` at entry —
  snapshotting `(nodeRuntime, server, generation)` — does its slow work with no
  locks held, and
  re-checks `gate.stillCurrent()` **inside the destination registry's lock** at
  the moment it registers.

Why that is airtight, per registry: the teardown bump happens-before the sweep,
and the sweep and the commit both hold the registry's lock, so they are totally
ordered. Commit first → the sweep observes the entry and removes it. Sweep
first → the commit's lock acquire observes the bumped epoch and refuses. There
is no third interleaving.

Two properties make the epoch strictly stronger than its predecessors (a
per-subsystem server-pointer compare or a boolean "stopping" latch):

- The check is a lock-free atomic load, so it can run under any registry lock
  without touching `runtimeController.mu` — a current-runtime pointer compare
  needs that lock, which would invert the lock order, forcing the check before
  the registry lock and leaving a check-to-commit window.
- A latch is cleared by the next `Start`, so an op stuck across two lifecycles
  would pass it and commit old-lifecycle state into the new node's world. An
  epoch compare refuses *any* later lifecycle.

What the epoch does **not** replace: the teardown sweeps themselves
(`closeAll*`), and the mid-lifecycle self-heal reaps (a funnel forwarder or
HTTP binding whose listener dies is reaped by its Serve goroutine). Those
handle resource death; the epoch handles registration ordering.

The cached in-process `LocalClient` is captured together with its runtime.
Ordinary calls derive their bounded context from `nodeRuntime.ctx` and validate
the captured generation before returning a result, so teardown cancels slow
reads and late old-generation responses surface as `staleRuntime`.

Adding a new registry? Acquire a gate at op entry, check it at the commit
point under your registry lock, sweep in `nodeRuntime.close` after controller
detachment and the epoch bump, and add a row to
`TestCommitGates_RefuseStaleAcrossRegistries` (`go/node_gate_test.go`).

## Lock ordering

Relevant nested orders; take locks left to right, never right to left:

```
runtimeController.configureMu  →  runtimeController.mu
serveConfigMu  →  servePublicationMu
funnelMu       →  ff.mu (per-forwarder)
watchMu  →  identityCache.mu
runtimeController.mu, httpBindingMu, tcpFdListenerMu,
udpFdBindingMu, tailnetHTTPTransports.mu, reactorMu, dartPortMu,
hostNetworkMu, state_store.mu   (leaf, no nesting)
```

Rules that keep it acyclic:

- `runtimeController.mu` protects candidate/current/draining transitions,
  terminal receipts, cleanup poison, and brief reads/publication of the frozen
  init tuple. It is released before
  filesystem, tsnet, LocalAPI, registry sweep, or close work. (`nodeEpoch`
  reads exist so commit-point checks never need it.)
- `runtimeController.configureMu` serializes one-time path resolution and may
  briefly acquire `runtimeController.mu` to read or publish the frozen tuple;
  no runtime path acquires those locks in the opposite order.
- Registry locks never nest with each other; `nodeRuntime.close` takes them one
  at a time.
- Calls that can block on the tailnet or the IPN bus (`ListenFunnel`, `Up`,
  dials) run with **no** package lock held; results are committed afterward
  under the registry lock with a gate check. One deliberate exception:
  `serveConfigMu` is held across *loopback LocalAPI* round trips
  (`GetServeConfig`/`SetServeConfig`/`StatusWithoutPeers`) — serializing that
  get-modify-set is the lock's entire purpose, and those are local-socket
  calls, not tailnet waits. Never extend that exception to the runtime
  controller or to calls that wait on the network.
- `UdpCloseBinding`/`closeAllUdpBindings` invoke a bridge's close callback
  only after releasing `udpFdBindingMu` (the callback re-enters the registry
  to deregister — Go mutexes are not reentrant).

## Diagnostics

`debugNodeState()` (`go/node_gate.go`) reports the epoch and live counts for
every registry. It is available through `Diag.nodeState()` for leak receipts
across repeated lifecycle generations.
