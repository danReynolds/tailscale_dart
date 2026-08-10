# Tailscale Dart rearchitecture plan

## Status

**Accepted; implementation in progress — R5 merged and R6 evidence underway
2026-08-10.**

This is the source of truth for the target architecture and implementation
order. It incorporates the August 2026 architecture alignment audit, review of
the current repository and open pull requests, Keybay's current platform
contract, and Tailscale v1.102.2 source behavior.

The current source now contains the `nodeRuntime`/supervisor foundations,
R4d's atomic secure-state cutover, R5's runtime-owned publication manager,
first-`Up` readiness gate, and exact publication handles, and the R7a-R7c
ownership moves: the outbound HTTP transport, the TCP/UDP/HTTP fd registries,
and the state watcher now live on `nodeRuntime` (2026-08-10). Persistent nodes use
the Keybay-backed encrypted StateStore, ephemeral nodes use an in-memory Store,
local forget is explicit, and the SQLite runtime/dependency are gone. This does
not mark the plan or a release complete. Hosted Funnel-tailnet and replacement
receipts plus the macOS production-Keybay persisted process-crash/restart
receipt passed on 2026-08-10. Android/mobile and remaining platform receipts,
R6 permission/backup/sidecar evidence, later ownership work, and the R10
integrated gate remain authoritative requirements below.

The two detailed decisions are:

- [Runtime ownership and fail-safe lifecycle](adr-runtime-ownership-and-lifecycle.md)
- [Encrypted node state and Keybay custody](adr-encrypted-node-state.md)

## North Star

> Tailscale owns Tailscale semantics and authority. `tailscale_dart` provides
> the smallest secure, performant, Dart- and mobile-native adaptation around
> it.

That gives us the following priority order when goals compete:

1. Correctness and protection of node identity.
2. Conformance with supported upstream Tailscale behavior.
3. Deterministic lifecycle and ownership.
4. Simple, maintainable code.
5. Measured performance on supported platforms.
6. Idiomatic Dart ergonomics without inventing alternate Tailscale semantics.

For each cache, registry, proxy, state mirror, or semantic adapter, use this
decision ladder:

1. Call a stable upstream API directly.
2. Add a thin translation at the Dart/Go boundary.
3. Optimize only after a representative benchmark identifies a real problem.
4. Keep bespoke machinery only when upstream lacks the needed capability or
   the FFI, mobile-security, or fd-capability boundary requires it.

Conformance means matching security, identity, policy, and lifecycle semantics;
it does not mean copying the Go API shape into Dart.

## Goals

- Make one lifecycle object own every resource associated with one
  `tsnet.Server`.
- Preserve the node epoch as a narrow stale-operation commit guard.
- Make every teardown cause use one safe, idempotent runtime-close path.
- Match upstream enrollment, logout, StateStore, Serve, and Funnel semantics.
- Encrypt the complete logical Tailscale StateStore with a key held outside the
  state directory, using Keybay as the required production Dart-side custodian.
- Integrate Keybay directly in the core package so persistent-state security has
  one maintained, documented path rather than an optional provider ecosystem.
- Keep the POSIX fd capability bridge and Go-owned protocol parsing where they
  are the simplest high-performance adaptation.
- Remove global registries, caches, locks, and persistence dependencies as
  runtime ownership makes them unnecessary.
- Make platform claims no broader than the receipts we have.

## Non-goals

- Reimplementing the Tailscale control plane, policy, identity model, or Serve
  model in Dart.
- A general internal dependency-injection framework.
- Supporting more than one simultaneously active public node in this package
  generation.
- Migrating pre-launch SQLite identities. Legacy local state is rejected and
  can be removed only by an explicit reset.
- Encrypting all process memory or defending against a compromised running
  process, root user, debugger, or hostile kernel.
- Windows support as part of this rearchitecture.
- In-place profile switching. A future switch is an identity transition that
  drains one generation and starts another; it never mutates a live runtime.
- Claiming mobile `tls.bind` before an alternate certificate path is verified,
  or claiming ServeConfig-based Funnel before real-device handshakes and a
  persistent-file inventory exist.

## Target architecture

```text
Application / Flutter UI isolate
  |
  | owns the core Keybay SecretStorage binding for one dedicated DEK
  | supervises the control worker and observes worker exit
  v
Dart control worker isolate
  |
  | serial lifecycle commands + binary DEK handoff
  | helper isolates only for bounded concurrent data-plane/control work
  v
Native runtime controller
  |
  | current runtime pointer + generation + preparing/closing coordination
  v
+-------------------------- nodeRuntime ---------------------------+
| one tsnet.Server                                                |
| one cached local.Client and HTTP transport                      |
| one encrypted StateStore + in-memory DEK copy                   |
| one persistent-state lease                                      |
| one watcher and one Serve/Funnel publication authority          |
| HTTP/TCP/UDP/TLS listeners, bindings, bridges, and handles       |
| lifecycle context, cancellation, generation, and close-once     |
+------------------------------------------------------------------+
  |
  | upstream tsnet, LocalAPI, netstack, WireGuard, DERP, policy
  v
Tailscale or Headscale control plane and tailnet peers
```

The public API may remain a singleton. Internally, one active `nodeRuntime`
maps one-to-one to one `tsnet.Server`, and a stopped Server is never reused.

## System invariants

The implementation is not complete until these are executable tests rather
than comments:

1. Every identity-bearing resource belongs to exactly one runtime generation.
2. A runtime's identity never changes. Re-enrollment creates a new runtime
   after explicit logout or local reset.
3. Slow work may commit a resource only while its captured generation is still
   current and while holding the destination registry lock.
4. A runtime is published as active only after `Server.Start` and all required
   construction-time configuration succeed.
5. `Server.Close` is called at most once, only after `Server.Start` returned
   successfully, and never concurrently with `Start`.
6. The Server closes before its StateStore, encryption-key copy, or state lease
   is released.
7. Every normal stop, startup abandonment, timeout, worker death, and partial
   failure converges on the same detach-then-close machinery.
8. A metadata-only format probe may run under the state lease before custody.
   Persistent StateStore content is never created, decrypted/opened, or replaced
   without both that lease and a valid 32-byte key from the core Keybay
   binding.
9. Missing keys, corrupt ciphertext, conflicting formats, and custody failures
   fail closed; none silently starts an empty plaintext identity.
10. `WriteState(id, nil)` deletes the value and future reads return
    `ipn.ErrStateNotExist`.
11. Supplying an auth key for an enrolled node does not erase or replace that
    node.
12. Serve and Funnel mutate one shared upstream `ServeConfig` authority. Every
    runtime automatically crosses the per-Server first-`Up` reset boundary
    before a Running/data-plane-ready state or publication API is exposed.
13. State-encryption DEKs cross FFI as bytes plus explicit length and never as
    UTF-8, JSON, or base64 text. The separate upstream auth key uses a bounded
    UTF-8 buffer. Neither secret appears in logs or error messages.
14. Every package-directed upstream log/sidecar path is inside the persistent
    runtime subtree or ephemeral scratch, and any temporary process-environment
    override is restored exactly before the generation completes.
15. Optional performance complexity has a benchmark, a denominator, and a
    removal threshold.

## Accepted decisions

### Keep the upstream boundary thin

Keep direct calls to `tsnet.Server`, its in-process `local.Client`, and public
upstream StateStore/Serve contracts. Keep Go responsible for tailnet
establishment and inbound HTTP parsing. Keep the POSIX fd reactor because it is
the capability and performance boundary that Dart needs, not a competing
Tailscale implementation.

### Introduce `nodeRuntime`, retain the epoch

Object ownership replaces scattered process globals as the primary lifecycle
model. The existing epoch remains because ownership alone cannot stop a helper
isolate that began under an old runtime from committing after teardown.

### Cache construction-time clients per runtime

`Server.LocalClient()` returns the same in-process client. Acquire it once,
configure `OmitAuth` before publishing the runtime, and drop it at close. The
`OmitAuth` exception is justified only because the client is bound to tsnet's
private in-memory LocalAPI transport; it must not migrate to a TCP LocalAPI
client.

Use `Server.CertDomains()` and `Server.TailscaleIPs()` when those are the only
values required. Use LocalAPI status for state, health, auth URLs, peers, and
the broader status model.

### Replace SQLite with a custom encrypted StateStore

Do not adopt plaintext FileStore and do not wrap it with per-value encryption.
Implement the small StateStore contract directly as one authenticated,
whole-map encrypted file. Model its cryptographic construction and contract
behavior after Tailscale's TPM store, while Keybay holds the data-encryption
key outside the state directory.

This is not a database workload. State persistence is not on the data plane;
SQLite, WAL files, and the native SQLite dependency add more code and a larger
security surface without a demonstrated benefit.

### Use Keybay directly for production custody

The core package depends directly on `package:keybay` and binds one stable
host-application namespace to one dedicated Keybay entry. Production callers
do not select or implement an alternate custodian. Keybay remains on the caller
isolate; only the key bytes are transferred to the control worker and then to
Go, so this still does not attempt to link a Dart library into Go.

The caller supplies one stable host application identifier. Core derives the
dedicated `<host-application-id>.tailscale` Keybay namespace and freezes it as
part of `init` identity. A narrow package-internal seam may inject a fake
Keybay backend for deterministic tests; it is not a production extension
point.

Keybay is touched only at storage lifecycle boundaries: initial DEK creation,
one read for a later persistent runtime or explicit idle authenticated probe,
and explicit local-forget deletion. Ordinary logout does not mutate Keybay. The
active `nodeRuntime` retains its DEK in memory and ordinary StateStore reads and
writes never call Keybay.

Persistent nodes fail closed when Keybay is unavailable. This deliberately
limits persistent support to Keybay's verified platform contract: iOS,
supported macOS modes, Android API 31+, and Linux desktop with an available
Secret Service. Ephemeral nodes use an in-memory StateStore, never invoke
Keybay, and remain available where the core runtime otherwise works.

### Make identity replacement explicit

An auth key is an enrollment credential, not a request to rotate an existing
identity. Never delete local state to force one into use and never infer
enrollment merely from private StateStore keys. When constructing a new Server,
pass a caller-supplied key to upstream and let `LocalBackend` decide whether the
persisted profile makes it irrelevant. A repeated `up()` on an already active
runtime cannot change immutable enrollment inputs and simply preserves the
current identity. Normal `logout()` follows the upstream remote-logout contract
and never deletes the lower-level StateStore container or DEK. On confirmed
success, upstream removes the current logical profile while the encrypted
container and application-installation DEK remain available for the next
enrollment. On failure, the outcome is indeterminate because the remote
operation may still have succeeded; retained data is recovery evidence, not a
promise that it is unchanged or retryable.

Provide a separately named destructive local-forget/reset operation for the
offline-recovery case. Its documentation must say that the remote node may
remain registered.

### One publication authority and a required first-Up bootstrap

The first successful `Server.Up` clears persisted Serve configuration and
advertised Services. Each new runtime therefore starts one automatic bounded
publication bootstrap as part of startup. NeedsLogin and NeedsMachineAuth stay
visible so an application can complete interactive enrollment, but the first
observed Running state is held behind the gate while the runtime calls
`Server.Up` exactly once. Running/data-plane readiness is published only after
that reset succeeds. TLS, Serve, Funnel, and any future `ListenService` wrapper
join the stored bootstrap result; none lazily becomes a second bootstrap
authority. A failed or indeterminate reset is fatal to that runtime, and a
second `Up` is not treated as a retry.

Serve and Funnel share one serialized read-modify-write authority, including a
bounded ETag-conflict policy. A publication made before Funnel must not be
erased when Funnel joins the completed bootstrap and invokes its upstream path.

### Automatic fail-safe teardown is local, not remote logout

The supervisor watches the worker isolate. Unexpected worker exit asks the
native controller to abandon preparation or detach and close the current
runtime. An `up()` timeout similarly marks the generation abandoned and
cancels what is cancellable; it never reports failure while allowing a late
successful runtime to become current.

This preserves persisted identity. Process crashes rely on OS resource cleanup;
finalizers are only a per-handle backstop. Neither worker death nor process
shutdown performs remote logout, because that would turn an implementation
failure into an identity-destructive network action.

### Be precise about encryption and mobile TLS

The encrypted StateStore protects Tailscale node/profile/Serve state. It does
not by itself encrypt every file under `tsnet.Server.Dir`. On any
non-Kubernetes platform whose publication path invokes upstream ACME handling,
including a future supported mobile path, upstream can write an account key and
TLS private keys as owner-only sidecar files. It can also write
`tailscaled.log.conf` containing a private log-stream credential and logs that
may contain authentication URLs. Those remain documented residual risks and
require backup exclusion while we pursue an upstream-supported encrypted
cert-store hook.

On iOS and Android, upstream compiles the LocalAPI certificate endpoint as a
404 stub, so `tls.bind` remains unsupported until an alternate certificate path
has real-device receipts. R5 removed the package's direct `ListenFunnel` path
and moved Funnel to shared `ServeConfig`/`AllowFunnel`; that implementation
avoids the package-side certificate call but remains **unqualified** until
real-device handshakes and the sidecar inventory pass. The private HTTP/TCP/UDP
path remains the mobile core.

Do not spoof Kubernetes environment detection to route certificates through
StateStore.

## Changes from the August audit draft

The original assessment remains the reasoning baseline, but current source and
the decisions made during review supersede these parts:

| Audit draft direction | Final determination |
| --- | --- |
| Investigate replacing SQLite with upstream FileStore. | Replace SQLite with a small custom whole-map encrypted StateStore. FileStore remains the semantic reference for the map contract and atomic file behavior, not the security boundary. |
| Evaluate an identity-preserving storage migration. | No migration. The package is pre-launch; recognized SQLite or plaintext FileStore artifacts fail with an explicit legacy-state error until the caller resets. |
| Treat storage largely as a simplification question. | Storage is a first-class mobile security boundary with Keybay custody, binary FFI, a cross-system state lease, crash states, and a full sidecar inventory. |
| Keep teardown strengthening near the registry refactor. | Add an explicit supervisor/native fail-safe contract for worker death, timeout, partial start, and abandoned non-cancellable work. |
| Assume existing TLS/Funnel platform claims carry forward. | `tls.bind` still needs another mobile certificate path. R5 removed direct `ListenFunnel`, but its ServeConfig Funnel path remains unqualified until real-device and sidecar receipts pass. |
| Treat the custom Start-error defer as ordinary cleanup. | Never call `Server.Close` when `Server.Start` returned an error; upstream already unwinds partial initialization and forbids Close before successful Start. |
| Treat Funnel's Up as a Funnel-local concern. | Every runtime starts one automatic per-Server `Up` bootstrap before Running/readiness; TLS/Serve/Funnel paths join its stored result so upstream's reset cannot erase an earlier mapping. |
| Leave auth-key replacement behavior implicit. | Match upstream: auth keys enroll fresh state; they do not silently destroy an existing identity. Logout and offline local forget are separate operations. |

The audit's central recommendations remain unchanged: upstream semantics are
authoritative, `nodeRuntime` becomes the ownership boundary, the epoch remains
the stale-commit guard, caches require current measurements, and the fd reactor
stays as the justified Dart/mobile data-plane adaptation.

## Live work disposition

Snapshot: 2026-08-10.

| Artifact | Decision | Required exit |
| --- | --- | --- |
| PR [#90](https://github.com/danReynolds/tailscale_dart/pull/90) | Merged 2026-08-10; it superseded #85 and #88. | Complete: Tailscale v1.102.2 / Go 1.26.5, repaired Android smoke shell, and genuine x86_64 boot/no-SIGSYS receipt landed in `4d98c22`. |
| PR [#89](https://github.com/danReynolds/tailscale_dart/pull/89) | Closed unmerged 2026-08-10; its useful convergence behavior and hosted tests were adapted into merged R5 replacement #99, without its temporary process-global ownership design. | Complete. The separate macOS crash/restart receipt passed; mobile/platform receipts remain evidence gates. |
| PR [#86](https://github.com/danReynolds/tailscale_dart/pull/86) | Closed unmerged 2026-08-10; superseded by the encrypted-state cutover. | Complete: SQLite was removed rather than upgraded. |
| Issue [#81](https://github.com/danReynolds/tailscale_dart/issues/81) | Closed 2026-08-10 by merged #90. | Complete: the Android runtime receipt is recorded in #90. |
| Issue [#87](https://github.com/danReynolds/tailscale_dart/issues/87) | Reopened after #99 because the in-process fix had landed but the persisted process-crash/restart receipt had not. That macOS production-Keybay receipt passed on 2026-08-10. | Close only after the receipt PR is reviewed and merged, linking both #99 and the exact hosted evidence. |
| Dirty SQLite contract worktree | Preserve only as test evidence. Do not merge its SQLite implementation. | Generalize nil-delete, exact-empty, reopen, and concurrency cases into the R4b StateStore suite; use non-opening legacy-file recognition in R2/R4d, then retire the worktree. |
| Dirty Serve/Funnel worktree | Its useful semantic deletion and live-test intent are incorporated into R5; its ownership model is superseded. | Retire only after the R5 replacement is merged and linked. |

No issue or PR should claim a supersession until the replacement is linked and
its acceptance criteria are recorded.

## Implementation workstreams

Each row is intentionally issue-sized. The dependency column is a merge-order
constraint, not an instruction to combine the work into one large PR.

Implementation snapshot: R2/R3 lifecycle foundations, R4a-R4d secure state,
R5 publication convergence, the first macOS R6 crash/restart receipt, and the
R7a-R7c transport/registry/watcher ownership moves are present in the current
source. The table
continues to state each workstream's full acceptance result; code presence does
not satisfy uncollected hosted, platform, or release receipts.

| ID | Workstream | Depends on | Required result |
| --- | --- | --- | --- |
| R0 | Architecture baseline | — | This plan and both ADRs are reviewed and linked from repository docs. |
| R1 | Upstream and Android baseline | R0 | Merge repaired #90 on v1.102.2 / Go 1.26.5+ with all normal CI and a real Android x86_64 boot receipt. |
| R2 | `nodeRuntime` and enrollment safety | R1 | Introduce controller/current runtime, cached LocalClient, Store/closer slots, generation, context, and one close path; remove the private `_machinekey`/creating-`HasState` preflight and every auth-key-triggered wipe/revoke. |
| R3 | Supervisor and lifecycle fail-safe | R2 | Worker exit, `up()` timeout, partial start, abandoned calls, and indeterminate remote logout converge safely; no late active runtime and no failed-logout deletion. |
| R4a | Direct Keybay integration | R2 | Add the core Keybay dependency, stable host-app namespace in `init`, dedicated DEK entry, and package-internal fake-backend tests without changing selected persistence. |
| R4b | Unwired encrypted Store | R2 | Implement the strict whole-map Go StateStore and reusable contract/fuzz/race/fault suite; do not patch SQLite. |
| R4c | Lease, custody phases, and binary DEK bridge | R3, R4a | Extend R3's tokens with process-local plus OS admission, possibly-committed write compensation, custody quarantine, and raw DEK FFI. |
| R4d | Atomic secure-state cutover | R4b, R4c | Switch probe/start/status/logout/forget/ephemeral together, enforce the no-migration matrix, then delete SQLite, `DuneHasState`, and the dependency in the same cutover. |
| R5 | Runtime-owned Serve/Funnel convergence | R4d | Repair #89 directly on `nodeRuntime`: one ServeConfig authority, automatic fatal first-Up bootstrap, bounded ETag policy, generation-bound handles, and no compatibility global. |
| R6 | Platform and secret-inventory receipts | R5 | Prove real Keybay restart behavior, crash recovery, enforceable permissions, host-owned backup exclusion, ephemeral cleanup, publication handshakes, and all upstream sidecars on supported targets. |
| R7a | Runtime-owned HTTP transport | R4d | Pool belongs to runtime and cannot survive identity change; returned HTTP clients capture their generation and fail stale; remove owner-keyed process cache. |
| R7b | Runtime-owned listener registries | R4d | Move HTTP/TCP/UDP/TLS registries and close sweeps onto runtime while retaining commit gates. |
| R7c | Runtime-owned watcher and snapshots | R4d | Watcher lifecycle belongs to runtime only for promised reactive streams; fresh snapshot calls remain authoritative LocalAPI reads. |
| R8 | WhoIs cache decision | R7c | Benchmark direct in-process `LocalClient.WhoIs` with `OmitAuth`; delete the connection/request identity mirror unless the frozen latency/load threshold justifies it; never put synchronous WhoIs on the UDP datagram hot path. |
| R9 | Direct upstream and error conformance | R7a–R7c | Use direct narrow APIs where appropriate and map upstream error classes without brittle message parsing. |
| R10 | Launch gate and documentation truth | R1–R9 | Full test matrix, platform receipts, secret inventory, performance receipts, updated README/site/API docs, and no stale architecture claims. |

### R1 — upstream and Android baseline

- Rebase/repair #90 rather than starting a competing upgrade PR.
- Pin Tailscale v1.102.2 and satisfy its Go 1.26.5 minimum.
- Correct the workflow shell so `pipefail` runs under Bash.
- Keep cross-build success separate from the emulator receipt.
- Match #81's actual receipt: boot the x86_64 example app, complete native
  initialization/reactor startup, keep the process alive, and observe no
  `SIGSYS`. Full node start/reconnect/stop remains an R10 device gate.

### R2 — `nodeRuntime` ownership and enrollment safety

- Introduce `runtimeController` and `nodeRuntime` without moving every registry
  in the same patch.
- Delete the `up(authKey == empty) -> DuneHasState -> _machinekey` preflight and
  let upstream produce NeedsLogin/NeedsMachineAuth. Never infer enrollment from
  a private StateStore key.
- Remove the hidden `RemoveAll(stateDir)`/best-effort revoke behavior from
  `up(authKey:)`. A supplied key is passed only while constructing a fresh
  Server; an active runtime preserves its identity and cannot be rebuilt merely
  to apply a different key.
- Treat the then-current SQLite Store as an opaque `ipn.StateStore` plus closer until
  R4d deletes it. Do not patch its nil-delete behavior or build a SQLite query
  probe. Generalize the useful worktree tests for R4b instead.
- Introduce the final storage-classifier seam now. Before R4d its implementation
  uses non-opening `lstat`/exact-name recognition: a clean root is absent and any
  `state.db`/WAL/SHM occupancy is legacy persisted state, never proof of
  enrollment. R4d replaces the classification policy with the authenticated
  secure matrix while retaining the same seam and legacy recognizer.
- Freeze configuration identity. `init` creates/verifies the app-owned base
  coordination directory, resolves its canonical native path/inode identity
  (so lexical, symlink, and case aliases cannot create two owners), and compares
  that identity plus the exact `logLevel`; R4a adds the exact validated host
  application identifier and derived Keybay namespace. Repeated `init` is a
  no-op only for that exact tuple.
- Freeze the active-`up` tuple as `(hostname, canonicalControlURL, ephemeral)`.
  Hostname is the exact validated string: empty is the upstream-default
  sentinel, leading/trailing whitespace is rejected, and case is not folded.
  Resolve null control URL to the package default; canonicalize with one shared
  parser/serializer that lowercases scheme/host, removes the matching default
  port, removes dot segments, maps an empty path to `/`, and rejects user-info,
  query, and fragment. Use that same canonical URL for comparison and native
  construction. Auth key is enrollment input and timeout is per-call wait
  policy; neither is runtime identity. A tuple mismatch neither tears down nor
  mutates the active runtime.
- Return `lifecycleBusy` for every concurrent `up` while startup is in flight,
  including a call carrying a different auth key. Join/idempotency applies only
  to an already active same-config runtime.
- Construct a candidate, call `Start`, get/configure the LocalClient, then
  atomically publish the completed runtime.
- On `Start` error, release caller-owned Store/key/lease resources but do not
  call `Server.Close`; upstream already unwinds partial initialization.
- Detach and bump the epoch under the controller lock. Perform blocking close
  work outside that lock.
- Close the Server first and caller-owned StateStore/key/lease last.
- Make repeated stop a no-op at the package API even though a second upstream
  `Server.Close` returns `net.ErrClosed`.
- Centralize and audit the current `TS_ENABLE_RAW_DISCO=false` compatibility
  assignment, but do not remove it or narrow its lifetime on the strength of
  R1: that receipt stops before `Server.Start`. Removal is an R10 source/unit
  conformance plus real Android `Server.Start` gate with the variable unset.
- Temporarily scope and restore `TS_LOGS_DIR` only around `Server.Start`,
  pointing it inside the Server Dir used at that phase, and inventory its
  sockstat logs. R2 deliberately preserves current ephemeral persistence;
  R4d owns the in-memory Store, fresh scratch Dir, scratch cleanup/sweep, and
  `TS_LOGS_DIR`-to-scratch cutover as one storage behavior change.

### R3 — lifecycle and supervisor fail-safe

- Supervisor receives an explicit worker `onExit` signal.
- Before sending preparation to the worker, the supervisor creates and retains
  the exact request-generation token. Native `beginPreparation(token, ...)`
  binds its candidate/lease to it, so worker death cannot strand an anonymous
  reservation.
- A rescue FFI entry point can cancel/abandon preparation and close the active
  generation without routing through the dead worker.
- If `Server.Start` is still executing, rescue marks the candidate abandoned;
  it never calls `Close` concurrently. When `Start` returns, success is closed
  immediately and failure releases caller-owned resources.
- New startup waits for abandoned preparation to finish; it does not create a
  second Server against the same state root.
- Timeouts in both non-cancellable `Server.Start` and the post-Start stable-state
  wait return only after the generation is quarantined. A late native success
  can never become current.
- The supervisor, not the worker, fails every pending RPC, removes stale
  live/transitional state, and is the only public event authority. After
  quarantine it uses the R2 storage-classifier seam; R4d changes its policy to
  the authenticated secure matrix. It then emits exactly one incident error. If
  probing fails, the one
  incident error includes the non-secret storage code/cause and the typed probe
  failure is cached for subsequent `status()`; no second `onError` is emitted.
  Rescue itself is event-silent.
- Tag shutdown intent by exact worker instance+generation, but invoke the
  idempotent event-silent `abandon(token)` for **every** `onExit`, including an
  expected one. The tag suppresses only the duplicate asynchronous incident
  error. If native close has already acknowledged, rescue is a no-op; if the
  worker exits between shutdown intent and that acknowledgement, rescue
  completes teardown. The original `down()` Future reports its close result.
  Consume the tag/signal once, make the Worker field replaceable, and resolve
  later calls through the newly bound instance.
- Make `logout()` remote-first. On timeout/failure perform no package-controlled
  deletion, detach/close the potentially mutated runtime, report
  `logoutIndeterminate`, and reconcile with a fresh runtime because the remote
  operation may already have succeeded. On confirmed success, preserve the
  lower-level Store and DEK after upstream removes the profile. The destructive
  `forgetLocalIdentity()` matrix lands separately with R4d's reset transaction.
- Until R7c moves watcher ownership, tag every Go-to-Dart status/error/peer push
  with the runtime generation and drop stale pushes. Do not bind a replacement
  worker port until the old watcher and quarantine are joined.
- Tests inject worker death and delay each startup boundary, assert event order,
  and prove token-qualified rescue cannot close a newer generation. Include an
  expected worker exit between shutdown-intent tagging and native-close
  acknowledgement; `abandon(token)` must finish close without a duplicate
  incident event.

R3 lands before a long-lived Keybay/file lease is introduced. R4 extends the
same rescue protocol across secure-state preparation rather than inventing a
second failure path.

### R4 — secure persistence vertical slice

Implement as a dependent review stack but one release gate:

1. **R4a:** direct core Keybay integration, required stable host application
   identifier, dedicated DEK entry, and package-internal fake-backend tests;
   extend `init` configuration identity with the derived Keybay namespace.
2. **R4b:** strict encrypted Go Store, initially unwired, with a reusable
   StateStore contract suite generalized from the SQLite worktree plus
   malformed-input, race, fault, and replay tests. No SQLite implementation
   change lands.
3. **R4c:** process-local and cross-process state lease, custody phases layered
   onto R3's supervisor-created preparation token, non-cancellable custody
   quarantine/compensation, and 32-byte binary DEK transfer. Treat any fresh-key
   write error as possibly committed. Native records the empty-envelope rename
   outcome behind an `envelopeWriteInFlight`/`writeDone` barrier before
   returning; `abandon(token)` waits for that outcome, then tells the supervisor
   `compensateKey` or `preserveCoherentPair` while retaining the lease, and
   `finishCustody(token)` ends the handoff.
4. **R4d:** atomic startup/status/logout/forget cutover, explicit operation/state
   and no-migration matrices, a durable reset-intent marker with idempotent
   recovery, presence-aware empty/nil semantics, ephemeral in-memory Store plus
   filesystem-only root occupancy and locked scratch cleanup, then deletion of
   SQLite source, tests, artifacts, `DuneHasState`, and dependency in that same
   cutover. Add `forgetLocalIdentity()` here and verify #86 is already closed.

Splitting these across releases would have created plaintext fallback or
mismatched key/file states. They were implemented as one current-source
vertical slice; the public release still waits for the downstream evidence
gates.

Ephemeral occupancy in R4d is intentionally filesystem-only. Ephemeral startup
never reads, writes, or deletes Keybay; it rejects recognized persistent
artifacts/non-empty package state under the configured root and otherwise uses
fresh scratch. A Keybay-only orphan cannot be observed without violating
that rule, so ephemeral mode leaves it untouched and a later persistent probe
reports it explicitly.

No package release was cut between R2 and R4d. That release gate is what makes it
safe to avoid polishing SQLite while the final runtime, rescue, and encrypted
Store land as reviewable dependent changes.

### R5 — runtime-owned publication convergence

**Implementation status:** the current source has the runtime-owned manager,
automatic bounded first-`Up` bootstrap, shared data-plane readiness gate,
three-attempt typed ETag policy, indeterminate-commit quarantine, and exact
generation/mapping-token handles with focused Go and Dart tests. Opt-in hosted
tests for Funnel tailnet reachability and Serve -> Funnel -> Serve replacement
passed serially on 2026-08-10 and also compile/skip without credentials.
The macOS production-Keybay persisted process-crash/restart stale-config
receipt also passed on 2026-08-10. Mobile handshakes and the remaining R6
platform/permission/backup/sidecar receipts stay authoritative.

- Rebase #89 after R2 and preserve its public `serve.forward` /
  `funnel.forward` convergence and useful live tests. The bootstrap result,
  ServeConfig mutation queue, and mapping tokens belong directly to the exact
  `nodeRuntime`; do not introduce a compatibility process global.
- Start the first-`Up` bootstrap automatically for every Server lifecycle.
  Preserve NeedsLogin/NeedsMachineAuth for interactive enrollment, but when the
  watcher first observes Running, withhold public Running and data-plane
  readiness and call `Server.Up` once. If the initiating `up(timeout:)` is still
  pending, use the lesser of its remaining deadline and the 30-second internal
  cap; if it already returned an interactive state, use a fresh 30-second
  runtime budget. Release the gate only on success. Before that Running
  observation, identity-bound operations fail immediately with typed
  `dataPlaneNotReady`; during the bounded bootstrap they join its one shared
  Future, and after completion they consume the stored result. Thus an API with
  no caller timeout still cannot wait indefinitely. TLS, Serve, Funnel, and
  future `ListenService` calls never trigger another bootstrap.
- Require every identity-bound TCP/UDP/HTTP/TLS/Serve/Funnel operation to enter
  through the same runtime `dataPlaneReady` gate, so state masking cannot be
  bypassed by a retained or early data-plane object.
- Use one mutation lock/queue. Allow at most **three total**
  fetch/apply/submit attempts within one operation deadline. Retry only
  `local.IsPreconditionsFailedError`, refetch current state, and reapply the
  pure operation; a conclusively known-not-applied non-conflict error returns
  immediately and a third conflict returns a typed `serveConfigConflict`.
- Classify Set errors as known-not-applied or indeterminate using typed/phase
  evidence. A timeout/response loss after possible apply quarantines and closes
  the generation before returning so no Serve/Funnel ingress survives without
  an owned handle. Test this after apply for both forward and clear.
- Treat first-`Up` bootstrap failure as fatal to the generation: detach and
  close it. After quarantine, emit exactly one asynchronous
  `publicationBootstrapFailure`, fail every gate waiter with the same cause,
  never publish Running, then publish `stopped` if the Server had started. This
  applies even when `up()` already returned NeedsLogin/NeedsMachineAuth; a later
  `status()` reports the new idle truth rather than replaying the old incident.
- Test Serve then Funnel, Funnel then Serve, replacement on the same port,
  clearing one path, TLS side effects, restart, and concurrent mutation. Add
  focused conflict tests for first-attempt success, one conflict that preserves
  an external mount, and three conflicts that stop exactly at the bound.
- Give every returned publication a unique mapping token. Closing/finalizing a
  replaced same-generation handle or an old-generation handle is an idempotent
  stale no-op and cannot clear its successor.
- Keep a confirmed publication in native pending-delivery custody until Dart
  validates and acknowledges the exact generation/mapping-token handle. Result
  loss must actively quarantine that runtime, with a bounded native timer as
  fallback when the helper or caller isolate cannot run compensation.
- The macOS production-Keybay crash-restart bootstrap receipt now leaves a
  publication active, SIGKILLs its process, reopens the same encrypted identity
  with ordinary `up()` and no auth key, and uses an already-running peer plus an
  exact old-port sentinel to prove the old configuration is cleared before and
  after Running/readiness. The separate R5 replacement receipt proves an old-
  generation handle cannot clear a recreated mapping.
- Update #89's body to remove stale snapshot/restore and Funnel-local `Up`
  language. Gate mobile ServeConfig Funnel separately; a desktop live test is
  not a mobile support receipt, and `tls.bind` remains a separate unsupported
  path.

### R6 — platform and secret-inventory receipts

- Completed on macOS CLI with production Keybay: fresh persistent enrollment,
  DEK presence without disclosure, SIGKILL, same stable node/IP reopen without
  auth, continuous stale-publication probing across first-`Up`, and explicit
  DEK/package-subtree reset all passed against hosted Tailscale on 2026-08-10.
- Prove fresh enrollment and restart with the real Keybay backend on each
  remaining supported target, not only with the package-internal fake backend.
- Run crash/response-loss fault cases across custody write, encrypted-envelope
  rename, reset-marker commit, key deletion, and subtree cleanup.
- Verify fail-closed permissions, Apple/Android host-owned backup exclusion,
  Linux/operator residual policy, and ephemeral scratch cleanup.
- Capture the complete persistent-file inventory after normal, TLS, Serve, and
  Funnel runs, including tailscaled/sockstats logs and certificate sidecars.
- Run real-device ServeConfig Funnel handshakes before qualifying mobile
  support. Upstream `StateEncrypted` telemetry is not a security receipt.

### R7 — move resources in small, reversible slices

For each resource family:

1. Add it to `nodeRuntime`.
2. Route construction and lookup through the captured runtime.
3. Preserve the epoch check at the registry commit point.
4. Close/sweep it from `nodeRuntime.close()`.
5. Delete the corresponding global, owner key, lock, and reset helper.
6. Add a repeated start/stop and stale-commit test.

Do not introduce a generic registry framework unless at least three migrated
families demonstrate the same useful abstraction.

Two process-globals are accounted for as sanctioned permanent bridge
infrastructure rather than R7 migration targets. The fd-reactor registry
(`go/reactor.go`) maps reactor ids to their kqueue/epoll pollers for the
Dart-owned reactor isolates; it is part of the retained POSIX fd capability
bridge and holds no identity-bound state. The Android host-network snapshot
cache (`go/netmon_snapshot.go`) backs upstream
`netmon.RegisterInterfaceGetter`, a register-once process-global hook, so the
latest host-supplied interface snapshot must stay readable across runtime
generations.

Identity-bound Dart capabilities participate in the same gate. R5 already makes
every `TailscalePublishedService` token/epoch-conditional and runtime-owned.
R5 also gives each returned HTTP client a runtime token and closed bit, so an
old client fails stale after restart instead of dialing as the new node. R7a
moves the underlying connection pool from its owner-keyed process cache onto
the runtime. Test both publication replacement and full down/up/new-resource
capability cases.

R7c keeps one watcher only for state the Dart API promises reactively: node
state, auth changes, node-list change notifications, and runtime errors where
available. Fresh `status()` and explicit node snapshot calls continue to query
the authoritative in-process LocalAPI; the watcher is not a universal mirror.

### R8 — benchmark-governed cache deletion

Measure direct `LocalClient.WhoIs` through the exact in-process client with
`OmitAuth` on macOS, Linux, iOS, and Android where practical. Record p50/p95/p99,
allocations/op, sustained CPU and throughput for 1, 8, and 32 concurrent TCP/HTTP
acceptors, both steady-state and during netmap churn, and compare the same
end-to-end accept path with the existing mirror.

The default decision is deletion. The provisional removal gate is direct-path
p95 at or below 1 ms, p99 at or below 5 ms, and no more than 10% end-to-end
throughput or CPU regression at the documented target accept rate on every
qualified platform. Retain a cache only if the direct path breaches an absolute
gate and the cache improves a failing metric by at least 20%; record that
workload, invalidation contract, benchmark commit, and the same removal
threshold beside its tests. LocalAPI remains semantic authority either way.

This decision applies to connection/request identity. Never replace UDP's
per-datagram metadata or another appropriate packet hot path with synchronous
LocalAPI `WhoIs` on every datagram; evaluate any UDP simplification separately.

### R9 — direct APIs and error conformance

- Replace full status calls with `CertDomains` or `TailscaleIPs` only where the
  narrower result is sufficient and the runtime is fully initialized.
- Keep LocalAPI for state, health, authentication URL, peer inventory, prefs,
  diagnostics, and WhoIs authority.
- Audit every Dart error mapping against a typed upstream error, HTTP status,
  IPN state, or explicit local precondition. Remove stable behavior that depends
  only on matching English error text.
- Keep `OmitAuth` bound to the cached in-memory LocalClient and add the
  construction-time trust-boundary assertion.
- Record each intentional semantic deviation with its mobile/FFI rationale and
  a focused test.
- Freeze distinct stable codes for `dataPlaneNotReady`,
  `publicationBootstrapFailure`,
  `serveConfigConflict`, conclusively `publicationNotApplied`,
  `publicationCommitIndeterminate`, `logoutIndeterminate`, and
  `localResetIncomplete`. In particular, never collapse a possibly-applied
  publication, a possibly-completed remote logout, and a failed local cleanup
  into one generic operation error.

### R10 — launch gate and documentation truth

- Run the complete verification matrix below from a clean checkout at the
  release commit.
- Record commit hashes, toolchain versions, target devices, and opt-in live-test
  environment without recording credentials.
- Produce the post-run persistent-file inventory and compare it with the
  encrypted-state threat model.
- Remove `TS_ENABLE_RAW_DISCO=false` only after a v1.102.2 source/unit
  conformance test proves raw discovery remains opt-in with the variable absent
  and a real Android run completes `Server.Start`, reconnect, and stop without
  `SIGSYS`. Until both receipts exist, keep the compatibility assignment and
  its process-global exception documented.
- Require host-app backup-exclusion receipts: Apple resource-value verification,
  Android no-backup-container or explicit backup-rule instrumentation, and an
  explicit operator policy/residual statement on platforms without a universal
  backup API. Core mode enforcement is fail-closed; backup configuration is a
  host integration precondition, not an unverifiable core-package claim.
- Update current architecture, concurrency, API status, README, developer site,
  changelog, package metadata, and examples to describe only shipped behavior.
- Close superseded PRs/issues only after linking the merged replacement and its
  receipts.
- Declare the launch gate failed if a supported platform lacks a runtime
  receipt, a timeout can leave a late runtime, StateStore plaintext is found, or
  mobile `tls.bind` is presented as supported without its certificate solution,
  or ServeConfig Funnel is claimed without its own real-device and sidecar
  receipts.

## Parallelism and merge order

After R1 lands:

- R2 lands the ownership boundary before either publication or secure-state
  integration, so neither needs a temporary process-global owner.
- R3 establishes rescue/timeout behavior before R4c introduces a state lease
  that can otherwise survive a worker failure.
- R4a direct Keybay work and R4b encrypted-Store tests may proceed in parallel
  after R2. R4c integrates only after R3; R4d is one atomic cutover.
- Do not publish a package release between R2 and R4d. This replaces the planned
  SQLite repair/probe bridge with a review stack that lands final code only.
- R5's replacement is implemented after R4d directly on `nodeRuntime`. Do not
  merge #89's temporary ownership design; close it after the replacement is
  merged and linked.
- R7 implementation may begin after R4d and migrates one resource family at a
  time, but no release containing that stack bypasses the R6 platform/inventory
  gate.
- R8 benchmarks can run in parallel, but cache deletion should rebase on the
  runtime-owned watcher.
- Documentation corrections for unsupported claims do not wait for code.

## Verification matrix

Every workstream owns focused tests, and R10 reruns the integrated matrix.

| Surface | Minimum evidence |
| --- | --- |
| Go unit/race | StateStore contract, lifecycle fault injection, publication serialization, registry stale commits, `go test -race`. |
| Dart unit/integration | Public errors and state transitions, supervisor worker-death path, timeout quarantine, handle idempotency. |
| Headscale E2E | First enrollment, reconnect with the same stable node, down/up, explicit logout, local forget, HTTP/TCP/UDP, repeated lifecycle. |
| Hosted Tailscale | Serve/Funnel ordering and clearing, desktop TLS handshake, control-plane logout failure/success, no stale publication. |
| Android | Cross-build plus real x86_64 and physical/representative device start/reconnect/stop; core private data plane. |
| iOS | Real-device start/reconnect/stop and core private data plane. |
| Mobile publication | `tls.bind` needs an alternate certificate path. R5 ServeConfig Funnel and HTTPS Serve remain unqualified until real iOS/Android handshakes and sidecar inventory pass. |
| Persistence security | Wrong/missing key, tamper/truncation, before/after-rename response loss, two-process lease, fail-closed permissions, platform-owned backup-exclusion receipt, plaintext secret inventory. |
| Performance | Startup/reconnect, StateStore write, LocalAPI/WhoIs p50/p95/p99, allocations/CPU and 1/8/32-acceptor throughput/netmap churn, memory/handle counts across repeated cycles. |

## Documentation truth policy

- This plan and the ADRs contain both implemented invariants and remaining
  targets; their status sections must distinguish the two.
- `current-architecture-and-api-feedback.md` and `concurrency.md` describe
  current `main` until the corresponding workstream lands.
- Each implementation PR updates the current-state docs and API status for only
  the behavior it actually changes.
- README, developer site, changelog, and platform tables may claim support only
  after the matching test receipt exists.
- Security wording must distinguish encrypted StateStore data from other tsnet
  files and from in-memory exposure.
- Architectural exceptions include a source link, rationale, tests, and a
  revisit trigger.

## Definition of complete

The rearchitecture is complete when:

- one runtime owns all identity-bound native resources;
- the only remaining process-global lifecycle state is the small controller,
  current pointer, generation, and necessary bridge ports;
- all stale async commits are rejected by executable epoch tests;
- all teardown causes converge and no late startup survives a timeout;
- existing identity is never implicitly destroyed by `up()`;
- StateStore semantics match upstream and persistent node state is encrypted
  with an externally custodied key;
- SQLite and its native dependency are gone;
- Serve/Funnel share one authority and first-Up reset cannot erase a prior
  publication;
- caches retained for performance have current cross-platform evidence;
- mobile feature claims match real-device evidence;
- public security documentation accurately describes protected data, residual
  sidecars, key custody, reset, and backup expectations.

## Primary upstream references

- [`tsnet.Server` v1.102.2 lifecycle and API](https://github.com/tailscale/tailscale/blob/v1.102.2/tsnet/tsnet.go)
- [`ipn.StateStore` contract](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/store.go)
- [Tailscale FileStore implementation](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/store/stores.go)
- [Tailscale TPM encrypted-store precedent](https://github.com/tailscale/tailscale/blob/v1.102.2/feature/tpm/tpm.go)
- [ServeConfig model](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/serve.go)
- [LocalClient Serve operations](https://github.com/tailscale/tailscale/blob/v1.102.2/client/local/serve.go)
- [Mobile-disabled LocalAPI certificate endpoint](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/localapi/disabled_stubs.go)
- [ACME certificate storage](https://github.com/tailscale/tailscale/blob/v1.102.2/feature/acme/certstore.go)
- [Secure node state storage](https://tailscale.com/docs/features/secure-node-state-storage)
- [Tailscale Funnel](https://tailscale.com/kb/1223/funnel)
