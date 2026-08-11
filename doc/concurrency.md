# Concurrency model

How the Go layer stays correct now that native calls arrive from more than one
Dart isolate. Read this before adding a lock, a process-global registry, or a
new offloaded call.

> **Current-state document.** Server, StateStore, DEK, state lease, scratch,
> publication/bootstrap manager, outbound HTTP transport, fd registries, and
> state watcher and measured accept-identity cache now live on `nodeRuntime`.
> The fd-reactor registry, Dart port, and Android host-network snapshot are
> sanctioned bridge infrastructure. See the
> [rearchitecture plan](rearchitecture-plan.md) and [runtime lifecycle
> ADR](adr-runtime-ownership-and-lifecycle.md).

## Two execution regimes

Every native call enters the Go layer from one of two places:

1. **The supervised worker isolate (serial FIFO).** Fast local calls (`status`,
   `prefs`, …) and the lifecycle calls (`start`, `stop`, `logout`,
   `up`, `down`) run one-at-a-time on a single Dart isolate. Two worker calls
   can never race each other. Lifecycle intent is also reserved in a
   supervisor-side FIFO before Android's asynchronous network snapshot, so an
   earlier `up()` cannot be overtaken by a later `down()` or `logout()` before
   its command reaches the worker. The caller isolate owns a replaceable worker
   instance; public calls resolve that instance at call time rather than
   retaining method tear-offs from a dead isolate.
2. **Helper isolates (concurrent).** The long, contended calls — `tcp.dial`,
   `diag.ping`, `serve.forward`, `funnel.forward`, the `tcp`/`tls`/`udp`/`http`
   listen and bind entry points, plus every HTTP client request admission — run
   on short-lived `Isolate.run` helpers. Data-plane offloads are capped at 32 by
   the shared gate in the supported caller isolate; see
   `lib/src/native_offload_gate.dart`. Native
   secure-state preparation, probe, reset, quarantine, and quiescence calls also
   use helper isolates. Rescue and lifecycle custody calls deliberately bypass
   the data-plane gate so a saturated connection workload cannot block cleanup.
   These calls are concurrent with the worker FIFO and with each other; native
   token admission and the state lease provide their ordering.

Before yielding to recovery or the shared helper gate, the caller isolate
captures the current runtime token for `tcp.dial`, `diag.ping`, the four
listen/bind entry points, Serve, and Funnel. `TailscaleHttpClient` retains the
token from its construction. Native
rejects a zero or superseded token before touching a replacement runtime's
Server or LocalClient. Listener and binding commands capture the same
exact token: `tcp.bind`, `tls.bind`, `udp.bind`, and `http.bind` are offloaded
like dial, because their native admission joins the runtime's one bounded
first-`Up` bootstrap and would otherwise park the serial worker isolate for
that whole window. Their close/teardown commands stay on the worker FIFO,
keyed by ids only a completed bind produces.

The consequence: **any offloaded call can race a lifecycle call.** A
`serve.forward` can be mid-flight while `stop()` tears the node down. Code on
these paths cannot assume the node it started with still exists when it
finishes.

## Supervisor tokens and fail-safe teardown

The caller isolate creates a unique runtime token before any asynchronous
startup preparation and carries it through the worker into Go. The native
`runtimeController` binds that exact token to one candidate/current/draining
generation. An abandoned token is retired even when timeout happens before the
worker reaches native code, so delayed preparation cannot later reuse it. A
pre-dispatch tombstone remains until either the late native entry consumes it
or Dart acknowledges that the originating Future settled/the worker exited;
that handshake keeps the race closed without retaining one token per timeout.

`up(timeout:)` establishes token-qualified quarantine before returning a
`startupTimeout` error. If non-cancellable `tsnet.Server.Start` is still
running, native code marks its candidate abandoned and does **not** call
`Server.Close` concurrently. The construction path observes abandonment when
`Start` returns: late success closes Server then Store; failure closes only the
caller-owned Store. Another lifecycle waits for that cleanup barrier.

Every worker exit invokes the event-silent rescue entry point from a helper
isolate. Pending worker RPCs fail promptly with `workerTerminated`; rescue
closes only the captured token, joins native cleanup and any retained custody,
and only then permits worker replacement. A runtime that had already started
authenticated its Store before publication, so successful quarantine can emit
`stopped` without a second Keybay read. An unpublished preparation emits no
terminal transition; the next explicit idle `status()` performs a fresh secure
probe. An exact expected-exit tag suppresses only the duplicate incident, not
rescue or state reconciliation.

Completed `down`/`logout` results are retained natively by token until the
caller isolate acknowledges receipt. That acknowledgement is a tiny in-memory
map deletion (no filesystem, network, or Tailscale work) and is the only native
call made on the caller isolate. If the worker exits after native completion
but before delivery, rescue consumes the retained result instead: cleanup
errors cannot be swallowed and a confirmed logout cannot be mislabeled as
indeterminate.

A failed Server close, Store close, state-lease release, scratch removal, or
startup unwind poisons lifecycle admission for the rest of the process with
`runtimeCleanupFailed`. Detachment is not reported as a clean `stopped`
transition unless quiescence was proved. This intentionally requires process
restart instead of opening a replacement over unknown resources.
`forgetLocalIdentity()` uses a durable encrypted-store reset marker for
destructive key/file cleanup; ordinary logout does not use it.

Native status, error, and peer pushes carry their runtime token. Dart drops a
push that is not owned by the worker's current/preparing token. `StopWatch`
cancels and joins both the IPN watcher and any in-flight debounced peer publish
before teardown completes, so a replacement port cannot race an old source.

## First-`Up` and publication authority

Every runtime owns one `publicationManager`, one `publicationBootstrap`, the
cached in-process LocalAPI client, its mapping-token table, and one mutation
mutex. Serve and Funnel are not separate registries: both mutate a fresh copy of
the same upstream `ServeConfig`; Funnel additionally selects the host:port
`AllowFunnel` mode.

The state watcher is the only trigger for the mandatory first-`Up` reset. Its
first Running observation starts exactly one bounded Go worker and suppresses
that Running event. Before Running, identity-bound data-plane calls fail
immediately with `dataPlaneNotReady`; while bootstrap is running they join its
single result; after success they proceed. Bootstrap success opens the gate
under the runtime's `watchMu` and posts synthetic Running only when Running is still the
watcher's latest state; a newer non-Running event is preserved and a later real
Running publishes normally. Watcher ownership, state publication, and
readiness therefore cannot split. A bootstrap/watcher failure before readiness
detaches and drains the exact runtime from a separate reaper; `Server.Close`
never races the `Up` worker.

Publication mutations hold `publicationManager.mu` across the bounded LocalAPI
get/copy/apply/set transaction. A typed ETag precondition failure releases no
partial ownership and retries from a fresh config, with three total attempts.
Known-not-applied errors return directly. An error after a Set may have applied
is tracked as an indeterminate mapping and triggers exact-generation quarantine
before Dart receives `publicationCommitIndeterminate`.

Each successful forward gets a runtime generation and monotonically increasing
mapping token. Exact handle close checks both without a LocalAPI round trip when
stale. Explicit `serve.clear`/`funnel.clear` is deliberately coordinate-based
and invalidates the package token only after a confirmed mutation. Runtime
keeps a confirmed mapping in pending-delivery custody until Dart validates and
acknowledges the exact generation/token receipt. Malformed or lost delivery
actively quarantines that runtime; a 30-second native timer is the fallback if
the helper or caller isolate cannot compensate. Explicit compensation preserves
the original synchronous Dart error as the sole error owner, while timer expiry
publishes one asynchronous runtime error. Runtime close cancels pending timers,
joins bootstrap first, performs a bounded best-effort cleanup of owned mappings,
then sweeps the remaining registries and closes Server before Store/lease; the
next runtime's mandatory bootstrap is the final stale-config barrier.

This acknowledgement proves delivery of validated metadata to the supervised
caller isolate; it is not a lifetime lease on the Dart object. The returned
handle's finalizer is best-effort, explicit `close()` is the deterministic API,
and runtime teardown remains the backstop for every package-owned mapping.

Logout is remote-first. It reconstructs a temporary runtime from persisted
state after `down()` and asks upstream to log out the current profile. Confirmed
success and failure both preserve the encrypted StateStore container and DEK;
only the upstream profile mutation differs. Failure or timeout closes the
possibly-mutated runtime and returns `logoutIndeterminate`.
That temporary runtime is not a public lifecycle transition: logout from an
already stopped node emits `noState`, not a second synthetic `stopped`.
That is an operation receipt, not a claim that the physical Store disappeared.
Idle reconstruction and later `status()` take the persistent-state lease and
authenticate the envelope with Keybay. They never classify a file by presence
alone or open legacy SQLite state.
Starting a fresh candidate first invalidates the cached reopen tuple; only a
successful `Server.Start` records the exact hostname, control URL, and
ephemeral setting it proved it applied. An abandoned late success therefore
remains safely revocable, while an unproven failed attempt cannot make logout
reuse an older control plane.

## Secure-state custody and state leases

Persistent state has two owners that cannot share one transaction manager:
Keybay runs asynchronously on the Dart caller isolate, while Go owns the
synchronous StateStore file. One supervisor-created token and one native state
lease join them.

- The native preparation acquires process-local admission and the OS advisory
  lock before any format probe or Keybay operation.
- Keybay returns one 32-byte DEK. Go authenticates or creates the whole-map
  envelope while the same token retains the lease, then the committed runtime
  owns the Store, in-memory DEK, and lease together.
- Keybay Futures are not treated as cancellable. Timeout or worker death
  quarantines the token but retains admission until the late Future and any
  exact-entry compensation settle. Native records whether the envelope rename
  committed and returns either `compensateKey` or `preserveCoherentPair`; Dart
  never guesses from a lost response.
- Runtime close orders Server before Store/DEK/lease. Idle status, idle logout,
  and local forget use the same lease rather than bypassing an active owner.
- Local forget makes its reset marker durable before deleting the exact Keybay
  entry, then removes only the package-owned subtree. An interrupted reset
  blocks ordinary lifecycle calls until local forget resumes it.
- Ephemeral startup uses the base-root lease only for a filesystem occupancy
  check. It never accesses Keybay, uses an in-memory StateStore, and gives tsnet
  a separately locked temporary directory that is removed before its live lock
  is released.

Routine encrypted StateStore reads and writes are protected by the Store's Go
mutex and use the runtime's in-memory DEK; they do not cross into Dart or
Keybay.

## The node epoch (teardown registration gate)

`go/node_gate.go`. A single mechanism closes every "late op commits state
behind teardown's sweep" race:

- `nodeEpoch` (atomic, written only under `runtimeController.mu`) counts
  lifecycles. The controller increments it **before** `nodeRuntime.close`
  sweeps any registry.
- An op that will register durable state (listener, UDP bridge, cached
  transport) calls `acquireNodeGate()` at entry —
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
(`closeAll*`) or mid-lifecycle self-heal when an HTTP binding's listener dies.
Those handle resource death; the epoch handles registration ordering. The
runtime-owned publication manager uses the same captured generation but commits
under its own manager mutex instead of a process-global registry.

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
runtimeController.hostNetworkMu  →  runtimeController.mu
nodeRuntime.watchMu  →  nodeRuntime.identity.mu
nodeRuntime.watchMu  →  publicationBootstrap.mu
runtimeController.mu, nodeRuntime.httpMu, nodeRuntime.fd.<family>.mu,
reactorMu, dartPortMu, publicationManager.mu,
encryptedStateStore.mu
  (leaf, no package-lock nesting)
```

R7a-R7c moved the transport slot (`httpMu`), the three fd registries
(`fd.tcpListeners`/`fd.udpBridges`/`fd.httpBindings`), and the watcher barrier
(`watchMu`) onto `nodeRuntime`; their nesting relationships are unchanged.

Rules that keep it acyclic:

- `runtimeController.mu` protects candidate/current/draining transitions,
  terminal receipts, cleanup poison, and brief reads/publication of the frozen
  init tuple. It is released before
  filesystem, tsnet, LocalAPI, registry sweep, or close work. (`nodeEpoch`
  reads exist so commit-point checks never need it.)
- `runtimeController.configureMu` serializes one-time path resolution and may
  briefly acquire `runtimeController.mu` to read or publish the frozen tuple;
  no runtime path acquires those locks in the opposite order.
- `runtimeController.hostNetworkMu` serializes the process-global Android
  netmon snapshot across idempotent refreshes and replacement starts. It may
  briefly acquire `runtimeController.mu` to admit/revalidate a refresh; no
  lifecycle path acquires them in the opposite order.
- Registry locks never nest with each other; `nodeRuntime.close` takes them one
  at a time.
- Calls that can block on the tailnet (`Up`, dials, listens) run with **no**
  package lock held; results are committed afterward under the destination
  registry lock with a gate check. One deliberate exception is
  `publicationManager.mu` across the in-process LocalAPI
  `StatusWithoutPeers`/`GetServeConfig`/`SetServeConfig` transaction:
  serialization of that optimistic get-modify-set is the lock's entire
  purpose. Never extend that exception to the runtime controller or to calls
  that wait on the tailnet.
- `UdpCloseBinding` and the runtime's registry drain invoke a bridge's close
  callback only after releasing the registry lock (the callback re-enters the
  registry to deregister — Go mutexes are not reentrant).

## Diagnostics

`debugNodeState()` (`go/node_gate.go`) reports the epoch and live counts for
every registry. It is available through `Diag.nodeState()` for leak receipts
across repeated lifecycle generations.
