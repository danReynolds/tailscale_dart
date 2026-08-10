# ADR: Runtime ownership and fail-safe lifecycle

## Status

**Accepted for implementation — 2026-08-09.**

This ADR defines the target lifecycle. It does not describe the current
process-global implementation on `main`.

## Context

One public Tailscale instance currently fans out across a process-global
`*tsnet.Server`, SQLite store, watcher, HTTP transport, publication managers,
listener registries, and subsystem locks. The node epoch correctly prevents
slow work from committing into a later lifecycle, but ownership is implicit and
teardown has to discover resources across the package.

That has produced several classes of risk:

- a resource can survive the identity that created it;
- every new registry must remember to participate in the stop sweep;
- a Dart timeout abandons a Future but does not cancel the native operation;
- an unexpected worker-isolate exit is not a fully specified lifecycle event;
- the current startup error cleanup calls `Server.Close` even when
  `Server.Start` failed;
- providing an auth key to a running node currently tears it down and deletes
  its identity;
- Serve and Funnel have separate locks despite mutating the same upstream
  configuration;
- the first `Server.Up` can clear a Serve mapping installed earlier in the same
  Server lifecycle.

Upstream v1.102.2 gives us important hard boundaries:

- `Server.Start` and `Server.Close` are each guarded by `sync.Once`.
- `Close` must not be called before or concurrently with `Start`.
- a Server is not restartable after close or failed initialization.
- `Server.LocalClient()` returns the one in-process client created by that
  Server.
- `Server.Close` does not close a caller-supplied StateStore.
- the first successful `Server.Up` clears persisted ServeConfig and advertised
  Services, and the internal once is consumed even if that reset fails.

## Decision

Introduce one `nodeRuntime` for one successful `tsnet.Server` lifecycle and a
small process-global `runtimeController` that coordinates candidates, the
current runtime, generation changes, and close.

The public Dart package remains single-node. The controller is coordination
state, not a second resource owner. Every identity-bearing resource lives on a
runtime or on a not-yet-published runtime candidate.

Conceptually:

```go
type runtimeController struct {
    mu         sync.Mutex
    generation uint64
    candidate  *runtimeCandidate
    current    *nodeRuntime
    closing    chan struct{} // non-nil while detached resources drain
}

type runtimeCandidate struct {
    generation uint64

    phaseMu   sync.Mutex
    phase     candidatePhase
    abandoned bool       // guarded by phaseMu
    startDone chan struct{}
    closeOnce sync.Once

    server        *tsnet.Server
    serverStarted bool // guarded by phaseMu; true only after Start returns nil
    store         ipn.StateStore
    closeStore    func()
    stateLease    stateLeaseHandle // nil until the encrypted-state slice
    secrets       secretOwner      // nil until the encrypted-state slice
}

type nodeRuntime struct {
    generation uint64
    ctx        context.Context
    cancel     context.CancelFunc
    closeOnce  sync.Once

    server     *tsnet.Server
    local      *local.Client
    store      ipn.StateStore
    closeStore func()
    stateLease stateLeaseHandle
    secrets    secretOwner

    publication *publicationManager
    watcher     *stateWatcher
    http        *http.Transport // moves here in workstream R7a

    // Runtime-owned HTTP/TCP/UDP/TLS registries and bridges are moved here
    // incrementally. Each keeps its own narrow lock.
}
```

Names and field grouping may change during implementation. The ownership and
ordering contracts may not.

The pseudocode is the final shape, expressed through storage-neutral ownership
slots so workstream R2 is independently landable with the current Store treated
as an opaque interface plus closer. R4 fills the lease/secret slots and replaces
the Store without first repairing SQLite. R7a moves the existing HTTP cache
behind the `http` slot; R2 temporarily continues to use and sweep the legacy
cache.

## Lifecycle state machine

```text
idle
  |
  | reserve generation (and, after R4c, persistent-state lease)
  v
preparing ---- validation/key/store error ----> cleanup ----> idle
  |
  | construct Server
  v
starting ----- Start error -------------------> cleanup ----> idle
  |                    (do not call Server.Close)
  | Start returned nil
  v
configuring -- client/config error -----------> closing ----> idle
  |
  | atomically publish current
  v
active -------- stop / timeout / worker exit -> closing ----> idle
  |
  | identity never changes in place
  +-------- logout / explicit local forget ---> closing ----> idle
```

Both identity operations close the runtime, but only
`forgetLocalIdentity()` continues into the secure reset transaction after
close. Confirmed logout preserves the storage container and its custodied DEK.

An abandonment request can arrive in `preparing`, `starting`, or `configuring`.
It marks the candidate stale immediately. It calls `Server.Close` only if and
after `Start` returned nil.

`active` above means the runtime is current and can expose interactive
NeedsLogin/NeedsMachineAuth state; it is not automatically data-plane ready.
The first observed upstream Running state enters the mandatory publication
bootstrap substate. Public Running and data-plane readiness remain suppressed
until that bootstrap succeeds. Failure takes the same closing edge and the
generation never becomes publicly ready.

## Construction protocol

### 1. Reserve a generation

Under `runtimeController.mu`:

- require no current runtime, candidate, or draining close;
- increment the generation;
- install a candidate before starting work;
- return typed `lifecycleBusy` for every concurrent `up()` while startup is in
  flight, even when configurations appear equal. This avoids silently joining
  requests that carry different auth keys. Idempotent same-config behavior
  begins only after a runtime is active; a second Server is never created.

Do not hold the controller lock across filesystem, Keybay, Tailscale, network,
or close operations.

### 2. Acquire persistent state safely

R2 introduces the final `idleStateClassifier` seam without a SQLite query. Its
temporary policy uses non-opening `lstat`/exact-name recognition: a clean root
is absent, while any recognized `state.db`/WAL/SHM occupancy is conservative
legacy persisted state, never evidence of enrollment. R3 uses that seam for
post-quarantine truth. R4d swaps in the authenticated secure matrix while
retaining the same seam and legacy-layout recognizer.

In the final persistent design, the candidate acquires the external state lease
before any state probe or Keybay operation. The caller isolate performs key
custody; the worker and Go receive only bytes. Detailed ordering is in
[the encrypted-state ADR](adr-encrypted-node-state.md).

The in-memory StateStore and scratch-directory behavior for ephemeral nodes is
part of the R4d storage cutover, not R2. R2 preserves today's persistence
behavior so its ownership refactor is behavior-neutral. In the final design an
ephemeral node uses an in-memory upstream StateStore and does not acquire or
inspect a persistent key.

### 3. Construct and start one Server

Populate all immutable Server fields before its first method call. Invoke
`Server.Start` without a package lock held.

The startup owner is the only goroutine allowed to close candidate resources
until `Start` returns. Candidate phase, abandonment, and `serverStarted` are
protected by `phaseMu`; `startDone` closes exactly once after the Start result is
recorded. Rescue locks only long enough to mark abandonment/cancel context. If
Start is still in flight it never reads an unsynchronized result or calls
`Close`; the startup owner observes abandonment after recording the result and
performs the ordered cleanup. If Start already returned, cleanup is scheduled
through `closeOnce`. This synchronization—not timing—prevents both a data race
and Close-vs-Start.

If it returns an error:

- rely on upstream's partial-initialization cleanup;
- do **not** call `Server.Close`;
- close the caller-owned StateStore;
- wipe the candidate's key copy best-effort;
- release its state lease;
- remove the candidate if its generation is still reserved;
- return a typed startup error.

If it returns nil, set `serverStarted` before any later fallible step. From that
point forward, all candidate cleanup must close the Server exactly once before
releasing the Store, key, or lease.

### 4. Configure construction-time clients

Acquire `Server.LocalClient()` once. Since `Start` already succeeded, this must
return the Server's in-process client or fail the candidate.

Set `local.Client.OmitAuth = true` before publishing the runtime. This is an
intentional adaptation for the private in-memory LocalAPI transport. Add a test
that the cached client uses the in-process custom Dial path; if the transport
ever changes, the test forces the trust decision to be revisited.

In R2, keep the existing owner-keyed outbound HTTP cache and teardown sweep as a
temporary compatibility bridge. R7a constructs the transport once on the
runtime and deletes that legacy cache. In both phases, no pooled connection may
survive a generation change.

When R4 lands, the candidate transfers its DEK into the encrypted Store and
wipes its temporary key buffer before commit. `nodeRuntime` does not retain a
second long-lived DEK copy; the Store is the sole long-lived in-process owner.

### Process-global upstream environment

The current bridge sets `TS_ENABLE_RAW_DISCO=false` and leaves
`TS_LOGS_DIR=<stateBaseDir>/tailscale/logs` in the process environment. Both are
global state outside runtime ownership. R2 centralizes and audits the raw-disco
compatibility assignment but does not remove or narrow it: R1 never calls
`Server.Start` and is not evidence for that change. R10 removes it only after a
v1.102.2 source/unit conformance test proves raw discovery stays opt-in with the
variable absent and a real Android `Server.Start`/reconnect/stop receipt shows
no `SIGSYS`.

Upstream still consults `TS_LOGS_DIR` while constructing the LocalBackend's
sockstat logger and exposes no per-Server field for it. Until that gap is fixed
upstream, candidate start uses one narrowly scoped package environment guard:

1. precreate the runtime-owned log directory at mode `0700`—the persistent
   Server Dir, or after R4d the ephemeral scratch Server Dir;
2. capture whether `TS_LOGS_DIR` was absent and its exact prior value;
3. set it to that runtime directory only around `Server.Start`, serializing all
   package starts through the guard;
4. restore the exact previous value/unset state in `defer`, on success, error,
   or abandonment.

The package never leaves a state-root-specific value installed between
generations. An upstream per-System/per-Server log-directory hook is preferred
when available; until then this bounded global adaptation and its interaction
with host-set `TS_LOGS_DIR` are conformance-tested and documented.

### 5. Commit atomically

Reacquire the controller lock and publish only if:

- the candidate is still the reserved candidate;
- its generation is current;
- it has not been abandoned;
- no close is in progress;
- every required construction step succeeded.

Otherwise close the successfully started candidate immediately. A late success
after a timeout or worker exit can never become current.

## Runtime access and the epoch

Fast runtime access captures `(runtime pointer, generation)` from the
controller. Operations that can create durable native state use the existing
gate protocol:

1. Capture the runtime and generation before slow work.
2. Perform blocking work without package locks.
3. At the final registry commit, hold the destination registry lock and verify
   that the controller generation is unchanged and the runtime is not closing.
4. If stale, close the new resource instead of registering it.

The epoch/generation is retained even after registries move onto the runtime.
A helper can still hold an object pointer after it has been detached; object
ownership alone is not a commit barrier.

Read-only calls also capture a runtime. They return a typed stopped/stale error
when the required upstream object is not safely initialized. In particular,
direct `CertDomains` and `TailscaleIPs` calls are never made before successful
Server initialization even though their API looks like a harmless read.

Returned Dart objects that can act as the node are capabilities, not timeless
facades. At minimum, the HTTP client and every `TailscalePublishedService`
capture their runtime generation plus a per-object closed bit. An HTTP client
retained across down/up fails with a stable stale-capability error; it never
falls through process-global FFI and sends as the replacement identity.

A publication handle's `close()` and finalizer submit the captured generation,
publication token, host/port/path, and visibility mode. Native removal succeeds
only if that exact same-generation mapping is still current. After restart an
old close is an idempotent stale no-op and cannot clear a new mapping at the
same coordinates. A replacement within the same generation
also gets a new unique mapping token, so closing the replaced handle cannot
remove its successor. Finalizers use the identical conditional path and never
issue an unqualified clear.

## Publication bootstrap

`Server.Up` is a special lifecycle boundary, not a general status probe.

Each runtime owns one `publicationManager` with one bootstrap result and one
ServeConfig mutation queue. R5 lands those fields directly on the R2
`nodeRuntime`, together with unique mapping tokens captured by every returned
publication handle. There is no compatibility publication global and no later
ownership migration.

Startup automatically starts the bootstrap; a publication API is never its
trigger:

1. Start the watcher and continue exposing NeedsLogin/NeedsMachineAuth so the
   host can complete interactive enrollment or approval.
2. When that watcher first observes Running, do not publish Running or
   data-plane readiness yet.
3. Call `Server.Up` exactly once with a bounded context. If the initiating
   `up(timeout:)` Future is still pending, use the lesser of its remaining
   deadline and the 30-second internal bootstrap cap so its timeout still bounds
   the whole operation. If `up()` already returned NeedsLogin or
   NeedsMachineAuth and Running arrives later, use a fresh standalone 30-second
   runtime budget. It is never `context.Background()`. On either deadline, the
   initiating call/error is completed only after generation quarantine.
4. Require the upstream ServeConfig/Services reset to succeed, store the result,
   then release Running/readiness and publication operations.
5. TLS, Serve, Funnel, and every future API that invokes or depends on `Up`
   consults the stored result. None can start or repeat the bootstrap lazily.

The runtime exposes one central `dataPlaneReady` gate, completed only after both
Running and bootstrap success. Every identity-bound TCP, UDP, HTTP, TLS, Serve,
Funnel, and future service operation acquires the runtime through that gate; a
retained object cannot bypass it. Waiting behavior is fixed by gate phase:

- before upstream first reaches Running—including `starting`, `needsLogin`, and
  `needsMachineAuth`—a data-plane call fails immediately with typed
  `dataPlaneNotReady` and the non-secret current lifecycle state;
- while the one bootstrap is actually running, a call joins that shared Future.
  Its wait is bounded by the bootstrap's remaining maximum 30-second budget, so
  an API with no caller timeout cannot wait indefinitely. An earlier
  caller-specific deadline abandons only that call and never schedules its
  operation to execute later;
- after success, calls proceed normally; after failure, existing waiters receive
  the stored `publicationBootstrapFailure`, and detached/old capabilities become
  stale in the ordinary generation-qualified way.

This is what “withhold data-plane readiness” means—it is not only a state-stream
mask around publication APIs. Fresh `status()` still queries authoritative
LocalAPI, then applies the local lifecycle gate: an underlying Running state is
reported as package `starting` while bootstrap is pending and never escapes as
public Running until the gate completes.

If the bounded Up/reset in steps 3–4 fails, the bootstrap is permanently failed
for that Server. An early `Up` failure might occur before the reset Once, while
another failure can occur during or after reset; the package cannot safely infer
which partial effects happened. The manager therefore makes one bootstrap
attempt, does not retry on the same runtime, and unconditionally detaches/closes
that generation.
Recording an unhealthy publication state is insufficient.

Failure delivery does not depend on an `up()` Future still being pending. After
quarantine/close, the supervisor emits exactly one `TailscaleRuntimeError` with
code `publicationBootstrapFailure` on `onError`, then publishes `stopped` if the
runtime had started. Every gate waiter fails with the same typed cause. If the
initiating `up()` is still pending, it also completes with the corresponding
typed operation exception; if `up()` previously returned an interactive state,
`onError` is the asynchronous owner of the later failure. No public Running
event is emitted. A later `status()` uses the idle classifier and reports its
current stopped/no-state/storage truth rather than replaying the historical
error; a new explicit `up()` creates a new generation.

Current `ListenTLS` invokes `Up` internally, so it must consult the manager
before entry: fail fast before Running, join an in-progress bootstrap, or consume
its completed result. The later internal call is not allowed to become a
separate package bootstrap authority. A future
`ListenService` wrapper follows the same rule.

The restart receipt does not call a publication API: leave a mapping active,
crash, restart, and perform ordinary `up()` only. The stale mapping must be
cleared before the restarted runtime can expose Running/readiness. This proves
the safety property is startup-owned rather than accidentally dependent on a
later Serve/Funnel call.

Serve and Funnel then use one serialized configuration mutation domain. One
operation has one overall deadline and at most **three total** attempts. Each
attempt:

1. fetch current `ServeConfig` and ETag;
2. apply the pure operation to a fresh copy;
3. submit the complete object;
4. retry only when `local.IsPreconditionsFailedError` says the ETag conflicted;
5. return a conclusively pre-dispatch/known-not-applied error immediately;
6. after the third ETag conflict, return a typed `serveConfigConflict` rather
   than overwriting an unknown concurrent writer;
7. treat a timeout, transport loss, or other result that cannot prove
   `SetServeConfig` was not applied as an **indeterminate commit**. Quarantine
   and close the generation before returning, because otherwise a forward could
   leave public ingress active without a returned handle (or a clear could have
   applied despite reporting failure).

The error adapter must classify known-not-applied versus indeterminate from
typed/local phase evidence, never by matching prose. If conclusive
classification is unavailable, choose indeterminate and close.

Never restore a captured pre-bootstrap config. Upstream intentionally clears
stale process-owned configuration.

## Enrollment and identity transitions

A runtime identity is immutable.

### `up()`

- Fresh persistent state plus an auth key may enroll.
- Authenticated non-empty StateStore data is not itself proof of enrollment;
  `_machinekey` can exist before a profile/node enrollment succeeds.
- When constructing a new Server, pass a caller-supplied auth key unchanged and
  let upstream `LocalBackend` decide whether persisted profile state makes it
  irrelevant. The package never wipes state or sets force-login to make it win.
- When a runtime is already active, repeated `up()` with the same effective
  hostname, control URL, and ephemeral mode is idempotent/joinable. A supplied
  auth key does not trigger reconstruction or identity replacement.
- Changed immutable hostname, control URL, or ephemeral mode returns a typed
  configuration-mismatch error. It is never silently ignored and never causes
  teardown. The caller must `down()` first, and identity-changing intent still
  requires `logout()` or `forgetLocalIdentity()`.
- Ephemeral mode is explicitly stateless in the target API: it requires an auth
  key for every new runtime, uses an in-memory Store and private scratch Dir,
  and is rejected when filesystem inspection finds recognized persistent
  artifacts or a non-empty package state subtree at the configured root. This
  check is deliberately filesystem-only: ephemeral mode never reads, writes,
  or deletes the custodian. A custodian-only orphan is left untouched and will
  be reported by the next persistent secure probe.

The immutable active-runtime comparison is exact and shared with native
construction:

- `hostname`: the exact validated string. Empty is the upstream-default
  sentinel; leading/trailing whitespace is rejected and case is not folded.
- `controlUrl`: null first resolves to the package default. One
  `canonicalControlURL` function lowercases scheme/host, removes the matching
  default port, removes dot segments, maps an empty path to `/`, rejects
  user-info/query/fragment, and supplies the same serialized URL to Go.
- `ephemeral`: exact Boolean equality.
- `authKey` is enrollment input, not runtime identity. It never causes an
  active runtime rebuild.
- `timeout` is a caller wait/deadline policy, not runtime identity.

Do not set `TSNET_FORCE_LOGIN` and do not delete the state directory to force an
auth key through upstream.

### `init()` configuration identity

`Tailscale.init` creates/verifies the app-owned base coordination directory and
uses the same canonical native path/inode identity as the state lease. Absolute
lexical, symlink, case, and same-inode aliases therefore compare as one root;
different canonical roots do not. R2 is idempotent only when that root identity
and the exact `logLevel` match the first call. After R4a, the caller-supplied
stable host `appId` and its derived Keybay namespace join that exact immutable
configuration tuple. A mismatch returns a typed configuration error and never
overwrites singleton state while a worker/runtime may still refer to it.
Applications that need a new configuration must do so in a new process
generation.

Core imports Keybay directly and lazily creates the package-owned
`SecretStorage` binding on the caller isolate. Callers supply `appId`; they do
not supply or compare a custodian object, and production exposes no alternate
custody interface.

### `down()`

`down()` detaches and closes the runtime while preserving encrypted state and
the custodied DEK. A later `up()` constructs a new Server and reconnects the
same identity.

### `logout()`

`logout()` is a remote identity operation:

1. ensure a runtime can reach the control plane, constructing one from existing
   state if the caller previously used `down()`;
2. call upstream logout and wait for success;
3. if it fails or times out, detach and close that potentially mutated
   generation while preserving the DEK/files, then return an indeterminate
   logout error; a later fresh runtime reconciles because the remote operation
   may nevertheless have succeeded;
4. on confirmed success, detach and close the runtime normally, wipe its
   in-memory DEK copy, release the state lease, preserve the Keybay DEK and
   encrypted storage container, and publish confirmed `noState`.

When the secure probe proves a genuinely fresh absent-state/absent-key root,
`logout()` is an idempotent no-op: it does not construct a runtime or contact the
control plane and its `Future<void>` completes normally; later `status()` reports
`noState`. An authenticated exactly-empty envelope/key pair proves only that
there is no recoverable local StateStore identity. It does **not** prove that no
remote device record was created—for example, a crash could occur after remote
registration but before state persistence. `logout()` therefore completes
normally without a remote call or deletion, preserves the interrupted pair,
and makes no revocation claim; `forgetLocalIdentity()` can remove it with the
same warning that a remote record may remain. Legacy, orphan, missing-key, and
corrupt conditions remain typed errors rather than being mistaken for no
identity.

### Local forget/reset

A separately named operation, `forgetLocalIdentity()`, is the explicit
offline/destructive escape hatch. It closes locally and destroys the
custodied key and owned state even if the control plane is unreachable. Its API
and docs warn that the remote device record or credential may remain valid.
It is an idempotent no-op for a proven absent-state/absent-key root. For an
authenticated empty pair, orphan key, or partial state it remains the explicit
local cleanup/recovery operation. All cases follow the operation-by-state matrix
in [the encrypted-state ADR](adr-encrypted-node-state.md#idle-operation-matrix)
rather than silently reporting success.

Neither `down`, worker death, timeout, nor process exit calls logout.

## Detach-then-close protocol

Every close cause calls one controller operation with an exact generation token
and a cause code. An explicit local-forget cause additionally requests transfer
of the state lease into a reset transaction. Under the controller lock it:

1. marks a matching candidate abandoned;
2. detaches the matching current runtime;
3. increments the generation before any resource sweep;
4. marks a close as draining;
5. cancels the runtime context;
6. releases the controller lock.

Outside the controller lock, `nodeRuntime.close(mode)` executes once:

1. stop accepting new publication/listener/transport work;
2. cancel and join publication bootstrap and background operations;
3. close publication handles and HTTP/TCP/UDP/TLS bridges/listeners;
4. stop and join the state watcher;
5. close the outbound HTTP transport and idle connections;
6. call `Server.Close` once;
7. close the caller-owned StateStore;
8. wipe in-memory key copies best-effort;
9. for ordinary close, including confirmed logout, release the persistent-state
   lease; only for explicit local forget, transfer it into a generation-bound
   `resetTransaction`;
10. remove only explicitly runtime-scoped scratch artifacts;
11. for ordinary close, signal draining complete. Reset mode keeps the
   controller draining until the transaction deletes/preserves state, releases
   the lease, and explicitly completes.

`resetTransaction` is the only owner allowed to span Server close, caller-side
Keybay deletion, and native filesystem removal, and only explicit local forget
can create or resume one. This prevents a new runtime from starting between key
deletion and directory disposition. Before Keybay deletion it durably installs
the external reset-intent marker defined by the encrypted-state ADR; failure to
establish that intent mutates neither key nor subtree. If key deletion later
fails, it preserves the marker and filesystem, releases the lease, completes
draining, and returns `localResetIncomplete`. It is generation-token
conditional and cannot reset a newer runtime. Confirmed logout never creates a
reset marker or calls Keybay `delete`.

Keybay deletion is a non-cancellable Future. Before awaiting it, native state
marks that token `resetCustodyActive`. Timeout or worker exit leaves the
controller draining and the lease quarantined until the Future settles. A late
success proceeds to exact subtree removal and marker cleanup; a late error
preserves the marker and subtree and returns typed incomplete/manual recovery.
Only then does the transaction release admission, so no new start can enter
between key deletion and directory disposition. A later explicit local forget
resumes the marker-owned transaction idempotently.

Package and registry locks are taken only long enough to detach a collection or
entry. No package lock is held while waiting on an upstream close, goroutine,
network call, or Dart port.

Public `stop`/`down` is idempotent: a second request observes idle or joins the
draining close. It does not call upstream `Server.Close` a second time.

## Worker-death and timeout fail-safe

The caller isolate is the supervisor and installs the worker's `onExit` handler
before accepting lifecycle work.

### Unexpected worker exit

Before dispatching preparation to the worker, the supervisor creates and
retains a unique opaque request-generation token. The worker calls
`beginPreparation(token, stateRoot, mode)`, and native code binds the candidate
and any lease to that already-known token before blocking work. This guarantees
that worker death between native acquisition and response delivery cannot
strand a reservation that rescue cannot name. The worker's
`startPrepared(token, config, keyBytes)` and every response carry it. Late
responses for an abandoned token are ignored.

On unexpected exit, the supervisor invokes a small rescue FFI entry point from
a live helper isolate so teardown cannot block the UI isolate. Rescue does not
need state held only by the worker. `abandon(token)`:

- marks only the matching candidate/runtime abandoned;
- cancels candidate/runtime contexts;
- detaches and closes a successfully started current runtime;
- retains preparation while any caller-side custody operation or compensation
  for that token settles;
- returns the native token's structured custody disposition
  (`compensateKey` or `preserveCoherentPair`) and teardown result while still
  retaining admission; the supervisor performs any requested custodian delete
  and calls `finishCustody(token)`;
- emits no public event.

The supervisor does not immediately spawn a replacement worker. It waits for
native quarantine/close completion, then permits a deliberate later `up()` to
create a new worker and runtime. The current `late final` Worker becomes a
replaceable supervisor-owned instance, and public calls resolve the current
instance at call time so ports are rebound after recovery.

The supervisor is the sole public event authority. It completes every pending
worker RPC promptly with a worker-exit error and removes every stale live or
transitional view (`starting`, `needsLogin`, `needsMachineAuth`, or `running`).
After native quarantine/close, it runs the `idleStateClassifier`: R3 uses R2's
non-opening layout policy and R4d replaces it with the secure policy. It then
emits exactly one structured incident error. If classification failed, that
same incident includes the non-secret probe code/cause and caches the typed
failure for subsequent `status()`; it does not emit a second `onError`. On a
successful classification it publishes `noState` or stopped-with-persisted-state
as truthful. It emits a `stopped` transition only when a started runtime
actually became stopped. The dead worker and rescue path never publish events.

The observable incident order is: mark token abandoned and block new work;
fail pending RPCs/remove stale running; await native quarantine/close and idle
classification; emit the one incident error (including any probe failure); then
emit `stopped` if and only if a started runtime actually became stopped. A
replacement worker is bound only after quarantine completes.

Expected worker termination is tagged in the supervisor with the exact worker
instance and generation before normal close, but **every** `onExit` still calls
idempotent, event-silent `abandon(token)`. The tag suppresses only a duplicate
asynchronous worker-incident error. If native close already acknowledged,
abandon is a no-op; if the worker dies after shutdown intent but before that
acknowledgement, rescue finishes teardown. The original `down()` Future—not the
exit tag—reports close success or failure. A missing/mismatched tag is
unexpected, and each signal/tag is consumed once so a late duplicate cannot
rescue or emit twice.

### Push compatibility before watcher ownership moves

R3 makes the Worker replaceable before R7c moves the process-global watcher and
push port onto `nodeRuntime`. As a required compatibility bridge, every native
status, runtime-error, and peer-list push carries its captured runtime
generation/token. Dart drops a push whose generation is not the current worker
binding. Quarantine cancels **and joins** the old watcher/background push
sources; the supervisor does not bind the replacement worker port until that
join completes. R7c later replaces this bridge with direct runtime ownership,
but cannot be relied upon to make R3 safe.

### `up()` timeout

Dart `Future.timeout` is not cancellation. The target implementation replaces
the current abandon-only behavior:

- the supervisor marks that exact generation abandoned;
- cancellable Go contexts are canceled;
- if non-cancellable `Server.Start` is still running, rescue records intent but
  does not call `Close` concurrently;
- when `Start` returns, the startup path observes abandonment and either closes
  the successful Server or releases caller-owned resources after failure;
- if Start already returned but `up()` is still waiting for a stable IPN state,
  timeout cancels that wait and detaches/closes the started runtime;
- the caller receives timeout only after the generation is quarantined so it
  cannot publish later;
- another `up()` waits for cleanup instead of opening the same state
  concurrently.

The timeout need not block until every upstream goroutine has drained, but it
must establish the no-late-commit invariant before returning.

### Process termination and finalizers

- Normal application lifecycle hooks may call `down()` for prompt cleanup.
- Abrupt process death relies on the OS to close descriptors and memory. It
  does not perform remote logout.
- Dart finalizers may close leaked individual handles, but they are not the
  runtime lifecycle controller and do not decide identity transitions.

## Threading and lock policy

- `runtimeController.mu` protects only candidate/current/generation/draining
  transitions and is always outermost.
- Registry locks never nest with one another.
- The generation is atomically readable so commit gates do not reacquire the
  controller under a registry lock.
- Publication configuration has one lock/queue for both Serve and Funnel.
- StateStore has its own leaf lock and is safe for concurrent upstream use.
- State lease acquisition and Keybay operations occur with no controller or
  registry lock held.
- Callbacks and close functions run after the owning registry lock is released.
- `runtimeCandidate.phaseMu` is a leaf lock. No caller waits on `startDone` or
  calls Server/Store cleanup while holding it.

The existing detailed lock graph in [`concurrency.md`](concurrency.md) remains
the current-state reference. Each registry migration updates it; the final
graph should be materially smaller.

## Error contract

Add structured internal error kinds and map them to stable Dart exception
types/codes. At minimum distinguish:

- lifecycle busy/closing;
- no active runtime;
- startup abandoned;
- startup timeout;
- upstream initialization failure;
- `dataPlaneNotReady` when a call arrives before upstream Running/bootstrap;
- `publicationBootstrapFailure` for the mandatory first-Up/reset gate;
- `serveConfigConflict` after the bounded ETag retry count;
- `publicationNotApplied` when typed/phase evidence conclusively proves the
  mutation did not apply;
- `publicationCommitIndeterminate` when a publication mutation may have
  applied and the generation was quarantined/closed;
- `logoutIndeterminate` when remote logout may have completed and the mutated
  generation was closed with evidence retained;
- `localResetIncomplete` when custodian or filesystem cleanup did not complete;
- secure-state errors defined in the encrypted-state ADR.

If upstream ignores an enrollment key because it resumed an existing identity,
that is not a lifecycle failure. The package may expose a non-secret diagnostic
only when it can derive that fact from an upstream-supported signal, not by
parsing private StateStore entries.

Never infer stable semantics by matching upstream English error messages when a
typed error, state, or local precondition is available. Preserve the upstream
cause for diagnostics without leaking auth keys, DEKs, StateStore values, or
private paths unnecessarily.

## Acceptance tests

### Construction and close

- Start success publishes exactly one runtime.
- Every injected pre-Start failure releases Store/key/lease and never calls
  `Server.Close`.
- Every injected post-Start failure closes Server exactly once before
  Store/key/lease.
- Stop twice and concurrent stop calls invoke one native close.
- Restart constructs a distinct Server, LocalClient, HTTP transport, watcher,
  and runtime generation.
- No blocking upstream close runs under the controller lock.
- `go test -race` forces `Start` return against token-qualified abandonment on
  both success and error paths; no unsynchronized phase access or concurrent
  `Close` occurs.
- The temporary `TS_LOGS_DIR` override points inside the runtime Dir and restores
  a previously absent, empty, or non-empty host value after every Start outcome.
- R2 pins the existing raw-disco compatibility assignment in one audited helper
  without claiming removal. R10 proves v1.102.2 opt-in behavior in source/unit
  tests and completes real Android Start/reconnect/stop with
  `TS_ENABLE_RAW_DISCO` absent before deleting that helper.

### Stale work

- Every registry refuses a commit after generation bump.
- An operation stuck across two complete lifecycles cannot commit into the
  third.
- Commit-before-sweep is removed by the sweep; sweep-before-commit is rejected
  by the gate.

### Timeout and worker failure

- Kill the worker during state preparation, `Server.Start`, configuration,
  active idle, and a long helper operation.
- Delay `Server.Start` beyond the Dart timeout and prove its late success is
  immediately closed and never published.
- Let `Start` succeed but delay the stable-state wait beyond timeout and prove
  the active runtime is detached and closed.
- Prove a new start cannot acquire the state lease until abandoned cleanup
  completes.
- Kill the worker after native reservation but before its response and prove the
  supervisor's pre-created token releases only that generation.
- Kill it during a non-cancellable custody Future and prove the lease remains
  quarantined until the Future and late-write compensation settle.
- Prove worker failure preserves persisted identity and does not invoke remote
  logout.
- Prove every pending RPC fails, exactly one runtime error is emitted, no stale
  live/transitional state remains, and the R2 layout policy publishes absent or
  persisted/error truth after quarantine; rerun the same suite against the R4d
  secure classifier's `noState`, stopped/persisted, and typed-error outcomes.
- Force the post-quarantine classifier itself to fail; its code/cause is folded
  into the single worker incident and cached for `status()`, with no second
  `onError`.
- Prove pre-Start and post-Start deaths obey the event order and that a
  generation-tagged expected worker exit emits no incident error. Force exit
  between shutdown-intent tagging and native-close acknowledgement and prove
  event-silent `abandon(token)` completes close exactly once.
- Prove the supervisor can construct/rebind a later fresh worker after native
  close.
- Delay old-generation status, error, and peer pushes until after worker
  replacement; all are dropped, and native port rebinding is impossible before
  old watcher/quarantine join completes.

### Configuration identity

- At R2, absolute/lexical, symlink, case-variant where applicable, and same-inode
  aliases resolve to the same native root identity; a different root or
  `logLevel` mismatches. At R4a, the exact validated host `appId` and derived
  Keybay namespace join that tuple; callers do not provide a custodian object.
- Every concurrent `up()` during startup returns `lifecycleBusy`, including a
  request with a different auth key; active same-config `up()` remains
  idempotent.
- Repeated active `up` with the same effective immutable config joins/returns
  current status.
- Exercise hostname empty-vs-explicit/default, surrounding-whitespace rejection,
  exact case, null/default and canonical-equivalent control URLs, and genuinely
  different URLs. A different auth key on an active runtime does not mismatch
  or rebuild; a different timeout is only a new wait policy. Changed hostname,
  canonical control URL, or ephemeral mode returns typed config mismatch and
  does not tear down the runtime.
- At R2, prove ephemeral persistence behavior is unchanged. At R4d, ephemeral
  start requires an auth key, uses only filesystem inspection to reject an
  occupied persistent root, never invokes any custodian method, uses a fresh
  `0700` scratch Dir/in-memory Store, and cleans/sweeps scratch by live lock.
  A custodian-only orphan is intentionally unobserved by ephemeral startup.

### Enrollment

- Reconnect without an auth key keeps the stable node ID.
- Supplying a new auth key with enrolled state does not wipe or replace it.
- Remote logout success lets upstream remove the current logical profile,
  closes the runtime, and reports confirmed `noState`; it preserves the Keybay
  DEK, authenticated envelope, and package-owned subtree for later enrollment.
- Remote logout failure performs no package-controlled deletion and reports an
  indeterminate outcome; it closes the potentially mutated generation and a
  later reopen reconciles possible remote success.
- Inject failure before local logout preference mutation, after that mutation,
  and after remote success with response loss; no failed/indeterminate logout
  leaves the old runtime current.
- Local forget works offline and produces the documented warning/result.
- For every row in the encrypted-state operation matrix, assert the exact
  `Future<void>` completion/error, remote-call count, key/file mutation, later
  status, and warning. In particular, logout on a clean absent state or
  authenticated exact-empty state completes normally without a remote call;
  exact-empty makes no
  remote-record/revocation claim and local forget removes the pair.
- Confirmed logout performs an ordinary close and never creates a reset marker
  or calls Keybay `delete`; a later runtime reuses the stable DEK. Only local
  forget keeps the controller draining and the lease held across caller-side
  Keybay deletion and native directory cleanup, so another start cannot enter
  the key/file handoff window.
- Late reset-custody delete success proceeds to directory cleanup; late error
  preserves the directory and returns manual recovery, with admission blocked
  until either outcome settles.

### Publication

- Leave Serve/Funnel configuration active, simulate process death, restart, and
  call ordinary `up()` without any publication API. Running/data-plane readiness
  stays hidden until the automatic bootstrap clears stale configuration.
- Hold startup at the first upstream Running observation and attempt early
  TCP/UDP/HTTP/TLS/Serve/Funnel work, including through retained Dart objects;
  calls made before that observation fail immediately with `dataPlaneNotReady`;
  calls made during the bounded bootstrap join its one Future; none reaches
  native data-plane/publication code before bootstrap succeeds and no wait can
  exceed the gate's remaining 30-second cap.
- At the same barrier, both watcher pushes and a fresh direct-LocalAPI
  `status()` report package `starting`, never Running; after success both expose
  Running, and after failure neither can resurrect it.
- Serve before Funnel is not erased when Funnel joins the already completed
  bootstrap and later invokes its upstream path.
- Funnel before Serve preserves the Funnel policy until intentionally replaced
  according to upstream same-port semantics.
- A failed first-Up reset is not retried on the same Server.
- Fail bootstrap both while the initiating `up()` is pending and after it
  returned NeedsLogin/NeedsMachineAuth. In both cases all gate waiters receive
  one typed cause, `onError` receives exactly one
  `publicationBootstrapFailure` after quarantine and before `stopped`, public
  Running is never emitted, and later `status()` reports the idle classifier's
  current truth without replaying that historical error.
- First-attempt success writes once; one ETag conflict refetches and preserves an
  externally added mount; three total conflicts stop with typed conflict. No
  unrelated error retries and no last-writer stale overwrite.
- Inject response loss after backend apply for both forward and clear. Each
  returns an indeterminate publication error only after the generation is
  quarantined/closed, so no unowned private or public publication remains live.
- Runtime close removes package-created publications and listener resources.
- Replace the same host/port/path within one generation, then call/finalize the
  old handle; the token-mismatched successor remains. Repeat across down/up and
  prove the old-generation handle cannot remove the new mapping either.

### Returned capabilities and watcher scope

- Retain an HTTP client across down/up; every send fails stale and none is
  dispatched through the new runtime. A newly obtained client succeeds.
- Publication and HTTP finalizers carry the captured generation and cannot act
  on a later runtime.
- Reactive streams update from the one runtime watcher, while fresh `status()`
  and explicit node snapshots call authoritative LocalAPI and do not return a
  stale watcher mirror.

## Consequences

### Benefits

- Security boundaries are represented by object lifetime instead of comments
  and owner IDs spread across globals.
- Close logic becomes enumerable and testable.
- Identity changes cannot inherit pooled connections or listeners.
- Worker death and timeouts become deterministic lifecycle events.
- Later deletion of redundant locks, maps, and caches is incremental.

### Costs

- The controller must handle a non-cancellable upstream `Start` without
  violating Close ordering.
- The supervisor needs a rescue FFI path independent of the worker.
- Runtime migration temporarily leaves some registries global; the epoch tests
  remain mandatory throughout.
- Correct remote logout after an earlier `down()` may require a short-lived
  runtime solely to contact the control plane.

## Alternatives rejected

- **Keep globals and add more sweeps.** This leaves identity ownership implicit
  and makes every feature a teardown audit.
- **Use only object ownership and delete the epoch.** A stale helper can retain
  a runtime pointer and commit after detach.
- **Call `Server.Close` on every startup error.** Upstream forbids Close before
  successful Start and already unwinds partial initialization.
- **Kill the worker and trust process cleanup.** The Go runtime and descriptors
  remain in the host process after an isolate failure.
- **Make timeout informational.** It permits a caller-visible failure followed
  by an invisible late-running node.
- **Automatically logout on failure.** It turns a local implementation fault
  into a destructive remote identity transition.
- **Force new auth keys by deleting state.** It conflicts with upstream
  enrollment semantics and can leave the old remote node valid.

## Upstream references

- [`tsnet.Server` fields and lifecycle](https://github.com/tailscale/tailscale/blob/v1.102.2/tsnet/tsnet.go)
- [`local.Client` construction and `OmitAuth`](https://github.com/tailscale/tailscale/blob/v1.102.2/client/local/local.go)
- [ServeConfig structure](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/serve.go)
- [LocalClient Serve get/set and ETag](https://github.com/tailscale/tailscale/blob/v1.102.2/client/local/serve.go)
- [LocalBackend logout ordering](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/ipnlocal/local.go)
- [Upstream log-directory policy](https://github.com/tailscale/tailscale/blob/v1.102.2/logpolicy/logpolicy.go)
- [Linux raw-disco opt-in](https://github.com/tailscale/tailscale/blob/v1.102.2/wgengine/magicsock/magicsock_linux.go)
- [Auth-key behavior](https://tailscale.com/docs/features/access-control/auth-keys)
