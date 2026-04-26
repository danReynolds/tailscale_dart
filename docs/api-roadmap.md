# RFC: Namespaced API for `package:tailscale`

**Status:** Draft — feedback welcome
**Branch:** `api-namespacing`
**Supersedes:** ad-hoc flat API surface on `Tailscale`

---

## Summary

Reorganize the public API of `package:tailscale` from a flat surface on
a single `Tailscale` class into topic-scoped namespaces
(`tsnet.tcp`, `tsnet.http`, `tsnet.prefs`, etc.), add the core
Tailscale capabilities Dart consumers are most likely to use first
(raw TCP, TLS, identity, diagnostics, advanced prefs), and clean up
API-hygiene issues surfaced in design review.

The roadmap is intentionally **consumer-first, not parity-first with
every Tailscale feature**. Private HTTP/TCP access, lifecycle, node
identity, and diagnostics are on the core path. More niche or
operator-heavy surfaces such as Taildrop, Profiles, rich Serve
builders, and extra Funnel ergonomics are explicitly demand-driven.

Strict ordering: **parity with today first**, hygiene second, core
capabilities third, optional capabilities last.

Implementation alignment is intentional: data-plane sockets and
listeners should stay close to `tsnet.Server`, while status,
diagnostics, prefs, profiles, serve config, and file-transfer features
should stay close to `local.Client` and the LocalAPI.

---

## Motivation

Our current public surface is ~10 methods on one class. To close
feature gaps against `tsnet.Server` + `local.Client` we need 50+ new
methods. Putting all of those flat on `Tailscale` sprawls the class
past what IDE autocomplete handles sensibly. Namespacing bounds the
surface per topic and matches both Tailscale's Go structure
(`tsnet.Server`, `local.Client`) and Dart conventions where they fit
(`package:http` `Client`, `Stream`-based input).

Separately, design review surfaced API-hygiene issues that will bite
users at runtime (non-nullable lookups, stringly-typed exit-node
handles, missing value-type equality). Those get fixed in one sweep
alongside the namespacing work so every downstream phase lands on a
clean foundation.

---

## Non-goals

Explicitly out of scope for this RFC:

- Replacing or reimplementing `tsnet` — we remain a wrapper.
- Exposing every Tailscale CLI / LocalAPI feature as a polished
  first-class Dart API. Some capabilities stay behind
  `localApi.request(...)` until there is demonstrated demand.
- Exposing Tailscale admin-plane APIs (ACL editing, device management).
  Those go through the admin REST API, not LocalAPI.
- Reimplementing Tailscale Drive (filesystem shares) in Dart. If a user
  wants it, they can hit the LocalAPI escape hatch (Phase 10).
- Changing any Go-side behavior beyond wrapping. No forking tsnet.

---

## Design principles

These rules apply across every phase. Deviations are called out in doc
comments.

1. **Use package-native transport types for raw data-plane primitives.**
   Do not expose fake `dart:io` sockets when the runtime cannot actually
   provide native Dart sockets. TCP uses `TailscaleConnection` /
   `TailscaleListener`; UDP should use a message-preserving datagram binding.
2. **One namespace per topic.** A topic earns a namespace at ≥2
   related methods, or 1 method with a cohesive noun (e.g. `udp`).
   Single-method cross-cutting utilities stay flat on `Tailscale`
   (`whois`).
3. **Verb conventions.**
   - `dial` for outbound — mirrors Go (`tsnet.Server.Dial`).
   - `bind` for inbound — mirrors Dart's naming convention. Avoids
     the collision `.listen(...)` has with `Stream.listen`.
4. **Value types are immutable** with `==`, `hashCode`, `toString`.
5. **Nullable returns** for operations that can legitimately not find
   a thing. Exceptions are for misuse, not missing data.
6. **Per-namespace error classes.** `TailscaleTaildropException`, etc.
   Callers pattern-match on type, not string.
7. **Identity by stable ID, not key material.** Public keys rotate on
   reinstall; `StableNodeID` / `TailscaleNode` references don't.
8. **Earn first-class API surface with real Dart use cases.** The core
   path prioritizes embedded/private-app jobs: connect a node, call a
   private HTTP/TCP service, expose a local HTTP/TCP service, inspect
   nodes, and diagnose connectivity. Features that mainly serve
   full-client, consumer-device, or ops-heavy workflows stay thin,
   optional, or escape-hatch-only until users pull them in.

## Product focus

### Core v1 path

These are the features that make the package useful even if nothing
else lands:

- Lifecycle/auth/status (`init`, `up`, `down`, `logout`, `status`,
  `nodes`, change streams).
- Private HTTP and TCP (`http.client`, `http.bind`, `tcp.dial`,
  `tcp.bind`).
- Identity/discovery and diagnostics (`whois`, `onNodeChanges`,
  `diag.ping`, `diag.metrics`, `diag.derpMap`, `diag.checkUpdate`).
- The LocalAPI escape hatch (`localApi.request(...)`) so advanced users
  can reach untyped endpoints without waiting on another release.

### Advanced but still plausible

These fit some Dart consumers, but they are not required for a strong
v1:

- `tls.bind`, `tls.domains()`
- `udp.bind`
- `prefs.*`
- `exitNode.*`
- `funnel.bind` as a thin transport surface, not a marquee feature

### Optional / demand-gated

These should not block v1 and should stay thin unless real users ask
for them:

- `profiles.*`
- `taildrop.*`
- `serve.*` beyond raw config get/set

## Upstream alignment

This package is aligned to two upstream surfaces, not one:

- **`tsnet.Server` for embedded data-plane primitives.** Outbound and
  inbound transport APIs should mirror `HTTPClient`, `Dial`, `Listen`,
  `ListenPacket`, `ListenTLS`, `ListenFunnel`, and future transport
  listeners such as `ListenService`.
- **`local.Client` for LocalAPI-backed control-plane features.**
  `whois`, diagnostics, prefs, exit-node control, profiles, serve
  config, taildrop, and the generic escape hatch should map to typed
  LocalAPI operations rather than inventing a parallel control model in
  Dart.
- **Prefer direct `tsnet` methods when the goal is "give me a
  transport primitive".** Prefer `local.Client` when the goal is
  "inspect or mutate daemon-managed state".
- **Track upstream version skew explicitly.** The current repo pin is
  `tailscale.com v1.92.2`. Features added in later upstream releases
  must be called out in the roadmap rather than silently assumed.

---

## Phase-by-phase plan

Each phase table is a checklist. As APIs land, tick them. Phases can
reorder or move items without breaking downstream phases' plans, as
long as the dependency graph below is respected.

### Dependency graph

```
Phase 1 (parity)
   │
   ▼
Phase 2 (hygiene) ────┬─── Phase 6 (prefs + exitNode) ───────────────┐
   │                   │                                              │
   ├── Phase 3 (fd-backed tcp) ─┬── Phase 5 (tls / udp / funnel) ────┤
   │                            └── Phase 8 (taildrop, optional)      │
   │                                                                   │
   ├── Phase 4 (LocalAPI one-shots) ───────────────────────────────────┤
   │                                                                   │
   ├── Phase 7 (profiles, optional) ───────────────────────────────────┤
   └── Phase 9 (serve, optional) ──────────────────────────────────────┘
                                   ▼
               Phase 10 (escape hatch + polish → v1.0 for the core path)
```

---

### Phase 1 — Functional parity with today

**Goal:** every existing caller migrates to the namespaced shape with
zero functional regression. No new capabilities exposed.

**Dependencies:** none.

| # | API                                      | Purpose                                                                  | Done |
| - | ---------------------------------------- | ------------------------------------------------------------------------ | ---- |
| 1 | `Tailscale.init({stateDir, logLevel})`    | One-time lib configuration at app startup                                | [x]  |
| 2 | `Tailscale.up({hostname, authKey, controlUrl, timeout})` | Start engine; connect to control plane                     | [x]  |
| 3 | `Tailscale.down()`                        | Stop engine; keep persisted credentials                                  | [x]  |
| 4 | `Tailscale.logout()`                      | Stop engine; wipe persisted credentials                                  | [x]  |
| 5 | `Tailscale.status()`                      | Snapshot of node state + IPs + health                                    | [x]  |
| 6 | `Tailscale.nodes()`                       | Current node inventory                                                   | [x]  |
| 7 | `Tailscale.onStateChange`                 | Stream of NodeState transitions (distinct-filtered)                      | [x]  |
| 8 | `Tailscale.onError`                       | Stream of background runtime errors                                      | [x]  |
| 9 | `Tailscale.http.client` *(was `.http`)*   | Pre-configured `http.Client` that routes via tailnet                     | [x]  |
| 10| `Tailscale.http.bind(port: ...)` *(was `.expose` / `.listen`)* | Package-native inbound HTTP server backed by fd streams | [x]  |
| 11| Migration: `example/example.dart`          | Update to new API surface                                                | [x]  |
| 12| Migration: `test/e2e/peer_main.dart`       | Update to new API surface                                                | [x]  |
| 13| Migration: `test/e2e/e2e_test.dart`        | Update to new API surface                                                | [x]  |
| 14| Migration: `test/ffi_integration_test.dart`| Retired with the old session/loopback transport tests                    | [x]  |
| 15| Migration: `CHANGELOG.md`                  | Document breaking renames                                                | [x]  |

**Exit criteria:**

- `dart analyze lib/ test/ hook/ example/` clean.
- Unit tests 20/20, FFI integration 29/29, e2e (against Headscale)
  18/18.
- Migration notes in `CHANGELOG.md`.

---

### Phase 2 — Foundation: cross-cutting API hygiene

**Goal:** close every critical/important finding from design review in
one sweep, so later phases don't re-open the same debates.

**Dependencies:** Phase 1.

| # | Item                                                    | Purpose                                                                             | Done |
| - | ------------------------------------------------------- | ----------------------------------------------------------------------------------- | ---- |
| 1 | `==` / `hashCode` / `toString` on value types           | Hand-rolled equality + debuggability. Covers TailscaleStatus, TailscaleNode, TailscaleNodeIdentity, WaitingFile, FileTarget, LoginProfile, PingResult, DERPMap/Region/Node, ClientVersion, TailscalePrefs, PrefsUpdate, FunnelMetadata | [x]  |
| 2 | Add `stableNodeId` to `TailscaleNode`                       | Upstream `ipnstate.PeerStatus` has `ID tailcfg.StableNodeID`; we dropped it. Required for type-safe `exitNode.use(node)` | [x]  |
| 3 | `Tailscale.whois(ip)` returns `Future<TailscaleNodeIdentity?>`   | Unknown IP returns null instead of forcing try/catch                                | [x]  |
| 4 | `profiles.current()` returns `Future<LoginProfile?>`    | Fresh install has no current profile — express it in the type                        | [x]  |
| 5 | `Tailscale.up()` returns `Future<TailscaleStatus>`, resolving on **first stable state only** | Resolves on `running`, `needsLogin`, or `needsMachineAuth`. Caller inspects `status.state` + `authUrl` to route next (interactive login, admin approval, or proceed). **Diverges from Go's `tsnet.Server.Up` which waits only on Running** — intentional; a Dart app can't hang until a human clicks a browser link. If startup fails or the implementation gives up waiting before a stable state is reached, throw `TailscaleUpException`; never return a transitional state such as `starting`. | [x]  |
| 6 | Prefs setter naming: all `set*` prefix                  | `setAdvertisedRoutes`, `setAcceptRoutes`, `setShieldsUp`, `setAutoUpdate`           | [x]  |
| 7 | `taildrop.get` → `taildrop.openRead` + `Stream<Uint8List>` | Matches `File.openRead`; efficient byte streaming                                | [x]  |
| 8 | `exitNode.use(TailscaleNode node)`                         | Type-safe exit-node selection                                                       | [x]  |
| 9 | `exitNode.useById(String stableNodeId)`                 | Escape hatch when only the stable ID is available                                   | [x]  |
| 10| Rename `MaskedPrefs` → `PrefsUpdate`                    | Less jargony than the Go term                                                       | [x]  |
| 11| Structured error fields on all `TailscaleOperationException` subclasses | Add `code: TailscaleErrorCode` (notFound / forbidden / conflict / preconditionFailed / featureDisabled / unknown), `int? statusCode`, `Object? cause`. Go-side translates `IsAccessDeniedError`, `IsPreconditionsFailedError`, HTTP status codes. | [x]  |
| 12| `TailscaleTaildropException`                            | Per-namespace error type                                                            | [x]  |
| 13| `TailscaleServeException`                               | Per-namespace error type                                                            | [x]  |
| 14| `TailscalePrefsException`                               | Per-namespace error type                                                            | [x]  |
| 15| `TailscaleProfilesException`                            | Per-namespace error type                                                            | [x]  |
| 16| `TailscaleExitNodeException`                            | Per-namespace error type                                                            | [x]  |
| 17| `TailscaleDiagException`                                | Per-namespace error type                                                            | [x]  |
| 18| Namespace constructors private                          | `Tcp._(worker)` etc., so users can't create unbound instances                       | [x]  |

**Exit criteria:**

- Every value type has equality tests (`test/equality_test.dart`).
- Public API surface locked — no renames past this point without a
  deprecation cycle.

---

### Phase 3 — POSIX fd-backed `tcp` primitives

**Goal:** enable non-HTTP node communication with package-native transport
types. TCP is not exposed as fake `dart:io` sockets; callers use
`TailscaleConnection` and `TailscaleListener`.

**Dependencies:** Phase 2 (data-type shapes must be settled for error
returns).

| # | API                                                     | Purpose                                                                              | Done |
| - | ------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---- |
| 1 | Go: POSIX socketpair handoff                            | Go bridges `tsnet` TCP connections to a private fd capability handed to Dart          | [x]  |
| 2 | Go FFI: `DuneTcpDialFd(host, port)`                     | Outbound fd-backed dial entry point                                                  | [x]  |
| 3 | Go FFI: `DuneTcpListenFd` / `DuneTcpAcceptFd`           | Inbound fd-backed listen/accept entry points                                         | [x]  |
| 4 | `tcp.dial(host, port, {timeout})` → `Future<TailscaleConnection>` | Open TCP connection to a tailnet node; wraps `tsnet.Server.Dial`          | [x]  |
| 5 | `tcp.bind({port, address})` → `Future<TailscaleListener>`  | Accept TCP connections on the tailnet; wraps `tsnet.Server.Listen("tcp", ...)`       | [x]  |
| 6 | Explicit output half-close                              | `conn.output.close()` half-closes writes without discarding input                     | [x]  |
| 7 | Package-native endpoint metadata                        | `TailscaleConnection.local/remote` and `TailscaleListener.local` expose tailnet endpoints | [x] |
| 8 | Listener close tears down native listener               | Closing `TailscaleListener` closes the Go-side tailnet listener                       | [x]  |
| 9 | Timeout contract is explicit and tested                 | `tcp.dial(timeout: X)` bounds the native tailnet dial                                 | [x]  |
| 10| **Platform verification: iOS + Android**                | Confirm fd handoff + background-isolate fd I/O works under the existing native-assets hook on both mobile platforms. If mobile sandboxing blocks this pattern, that needs to surface here — not in Phase 5 when three transports are downstream. | [x]  |
| 11| E2E byte-echo test                                      | Two nodes exchange arbitrary bytes via `tcp.dial` + `tcp.bind`                       | [x]  |
| 12| Go regression tests for fd handoff helpers              | Cover socketpair behavior and listener address parsing                               | [x]  |
| 13| Example: raw-TCP echo server/client                     | `/example/tcp_echo.dart`                                                             | [x]  |

**Exit criteria:**

- `dart test test/e2e/e2e_test.dart` passes a new `tcp lifecycle`
  group with byte-level assertions.
- Go tests cover socketpair fd adoption, accept/close behavior,
  half-close propagation, and listener lifecycle behavior.
- The timeout contract is documented in Dart doc comments and matched
  by tests; `tcp.dial(timeout: X)` must not silently take ~2x `X`
  unless the docs explicitly define timeout as per-stage rather than
  end-to-end.

---

### Phase 4 — LocalAPI one-shots

**Goal:** expose the read-only and simple-write LocalAPI calls that
don't require data-plane fd handoff. These are thin, typed wrappers over
`local.Client`. Proceeds in parallel with Phase 3.

**Dependencies:** Phase 2.

Note: the interactive-login flow previously listed here is folded into
Phase 2's new `up()` semantics — a no-authKey `up()` on a fresh dir now
resolves with `status.state == needsLogin` and a populated `authUrl`.
No separate work item.

| # | API                                            | Purpose                                                                         | Done |
| - | ---------------------------------------------- | ------------------------------------------------------------------------------- | ---- |
| 1 | `Tailscale.whois(ip)` → `TailscaleNodeIdentity?`        | Identify a tailnet IP's owner / hostname / tags                                  | [x]  |
| 2 | `Tailscale.onNodeChanges` → `Stream<List<TailscaleNode>>` | React to node inventory changes without polling                          | [x]  |
| 3 | `diag.ping(ip, {timeout, type})` → `PingResult`| Round-trip + route diagnostic (`direct` / `derp` / `unknown`); accepts MagicDNS names | [x]  |
| 4 | `diag.metrics()` → `String`                    | Prometheus-format metrics snapshot from the embedded runtime                     | [x]  |
| 5 | `diag.derpMap()` → `DERPMap`                   | Current relay region + node map                                                  | [x]  |
| 6 | `diag.checkUpdate()` → `ClientVersion?`        | Latest tsnet version if newer than embedded, else null                           | [x]  |
| 7 | `tls.domains()` → `List<String>`               | Cert SANs; preflight for `tls.bind`                                              | [x]  |

**Exit criteria:** each method has a unit test; e2e covers the happy
path for each diagnostic.

---

### Phase 5 — Remaining transports

**Goal:** extend the package-native transport model to remaining
transports. UDP should preserve datagram boundaries; TLS/Funnel need a
fresh surface decision rather than inheriting the old fake-socket model.

**Dependencies:** Phase 3.

| # | API                                                          | Purpose                                                                   | Done |
| - | ------------------------------------------------------------ | ------------------------------------------------------------------------- | ---- |
| 1 | `tls.bind(port)` surface decision                             | Decide package-native TLS listener shape vs. a higher-level HTTP/TLS helper | [ ]  |
| 2 | UDP datagram binding backend                                 | Preserve `[peerIP, peerPort, payload]` message boundaries without stream-shaped semantics | [x]  |
| 3 | `udp.bind({port, address})` → `Future<TailscaleDatagramBinding>`  | UDP datagram listener on a tailnet IP                             | [x]  |
| 4 | `funnel.bind(port, {funnelOnly})` surface decision            | Public-internet HTTPS via Funnel. **Advanced / optional:** keep the surface thin and close to upstream; do not block v1 on additional ergonomics. | [ ]  |
| 5 | Funnel request metadata                                      | Expose original public-client source IP + SNI target on whichever listener/request type Phase 5 settles. | [ ]  |
| 6 | Example: all-transports demo                                 | `/example/transports.dart` exercising TCP + TLS + UDP + Funnel            | [ ]  |

**Exit criteria:** demo runs against a live tailnet; CI e2e covers
each transport. Funnel/TLS tests are opt-in (see Testing matrix below)
since Headscale doesn't support them.

---

### Phase 6 — Prefs + Exit Node

**Goal:** advanced routing config. First API surface that writes state
beyond the engine lifecycle. Backed by `local.Client` preference and
exit-node APIs, not by `tsnet.Server`.

**Dependencies:** Phase 2.

| # | API                                                        | Purpose                                                                 | Done |
| - | ---------------------------------------------------------- | ----------------------------------------------------------------------- | ---- |
| 1 | `prefs.get()` → `TailscalePrefs`                           | Current preferences snapshot                                            | [ ]  |
| 2 | `prefs.setAdvertisedRoutes(routes)`                        | Advertise subnet routes behind this node                                | [ ]  |
| 3 | `prefs.setAcceptRoutes(bool)`                              | Accept subnet routes advertised by other nodes                          | [ ]  |
| 4 | `prefs.setShieldsUp(bool)`                                 | Block all inbound connections                                            | [ ]  |
| 5 | `prefs.setAutoUpdate(bool)`                                | Opt in/out of automatic tsnet updates                                   | [ ]  |
| 6 | `prefs.setAdvertisedTags(tags)`                            | Replace advertised ACL tags                                             | [ ]  |
| 7 | `prefs.updateMasked(PrefsUpdate)`                          | Atomic multi-field prefs edit                                            | [ ]  |
| 8 | `exitNode.current()` → `TailscaleNode?`                       | Node currently being used as exit, or null                              | [ ]  |
| 9 | `exitNode.suggest()` → `TailscaleNode?`                       | Control-plane-recommended exit node (latency-based)                     | [ ]  |
| 10| `exitNode.use(TailscaleNode)`                                 | Route all outbound traffic through this node                            | [ ]  |
| 11| `exitNode.useById(String stableNodeId)`                    | Same as `use`, but for the case where only the stable ID is known       | [ ]  |
| 12| `exitNode.useAuto()`                                       | Set `AutoExitNode` / `auto:any` mode — let the control plane pick. Upstream prefs support this; future-proofs the API against requiring a user-facing "auto" button to land as a breaking redesign. | [ ]  |
| 13| `exitNode.clear()`                                         | Stop routing through an exit node                                        | [ ]  |
| 14| `exitNode.onCurrentChange` → `Stream<TailscaleNode?>`         | React to exit-node changes (including external)                          | [ ]  |

**Exit criteria:** e2e covers advertising a route, using/clearing an
exit node (manual + auto), and shields-up behavior.

---

### Phase 7 — Optional: Profiles

**Goal:** multi-account / multi-tailnet support — one device, several
identities. Backed by `local.Client` profile APIs.

**Demand gate:** not on the core v1 path. Only prioritize if real Dart
consumers need one embedded node to switch between work/personal/dev
tailnets inside the app itself.

**Dependencies:** Phase 2.

| # | API                                                | Purpose                                                               | Done |
| - | -------------------------------------------------- | --------------------------------------------------------------------- | ---- |
| 1 | `profiles.current()` → `LoginProfile?`             | Currently active profile, or null on fresh install                    | [ ]  |
| 2 | `profiles.list()` → `List<LoginProfile>`           | All profiles persisted on this node                                   | [ ]  |
| 3 | `profiles.switchTo(LoginProfile)`                  | Disconnect + reconnect with the target profile's credentials          | [ ]  |
| 4 | `profiles.switchToId(String id)`                   | Escape hatch when only the ID is available                            | [ ]  |
| 5 | `profiles.delete(LoginProfile)`                    | Remove a profile and its persisted credentials                        | [ ]  |
| 6 | `profiles.deleteById(String id)`                   | Escape hatch when only the ID is available                            | [ ]  |
| 7 | `profiles.newEmpty()`                              | Create an empty slot for the next `up()` with a fresh authkey         | [ ]  |

**Exit criteria:** e2e creates two profiles, switches between them,
deletes one.

---

### Phase 8 — Optional: Taildrop

**Goal:** node-to-node file transfer.

**Dependencies:** Phase 3 or an equivalent LocalAPI-backed
byte-stream path.

Taildrop should follow the simplest stream-safe implementation path
available at the time. If LocalAPI-backed streaming lands cleanly
before the general socket bridge is mature enough, Taildrop can move
earlier rather than waiting on unrelated transport work.

**Demand gate:** not on the core v1 path. Upstream Taildrop is still an
alpha feature and is targeted at transfers between a user's own
personal devices, not generic service-to-service or tagged-node
workflows. Keep this namespace thin and do not build product-level file
management on top of it.

| # | API                                                                      | Purpose                                                                                     | Done |
| - | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ---- |
| 1 | `taildrop.targets()` → `List<FileTarget>`                                | Nodes you can send files to right now                                                       | [ ]  |
| 2 | `taildrop.push({target, name, data, size?})`                             | Stream a file to a node                                                                      | [ ]  |
| 3 | `taildrop.waitingFiles()` → `List<WaitingFile>`                          | Files received and not yet picked up                                                         | [ ]  |
| 4 | `taildrop.awaitWaitingFiles({timeout})` → `List<WaitingFile>`            | Block until at least one file is available, or timeout                                      | [ ]  |
| 5 | `taildrop.openRead(name)` → `Stream<Uint8List>`                          | Stream a received file's bytes (caller owns persistence)                                     | [ ]  |
| 6 | `taildrop.delete(name)`                                                  | Discard a received file without reading                                                      | [ ]  |
| 7 | `taildrop.onWaitingFile` → `Stream<WaitingFile>`                         | Reactive version of `awaitWaitingFiles`                                                      | [ ]  |
| 8 | E2E file-roundtrip test                                                  | Two nodes push / receive a file with checksum verification                                  | [ ]  |

**Exit criteria:** e2e sends a 1MB file end-to-end and verifies bytes
on both sides.

---

### Phase 9 — Optional: Serve raw config

**Goal:** programmatic access to what `tailscale serve` / `tailscale
funnel` do on the CLI.

**Dependencies:** Phase 2. **Also:** upgrade `tailscale.com` Go module
pin to the latest stable at the time Phase 9 starts (current pin
`v1.92.2` is missing `Services`, `AllowFunnel`, `Foreground`,
`ListenService`, and per-service ETag introduced in later upstream
versions). Bump + audit the diff before modelling `ServeConfig`.

**Demand gate:** not on the core v1 path. The goal here is raw
`ServeConfig` access, not a broad Dart DSL for every Serve/Funnel
handler combination. `http.bind()` already covers the common Dart
"handle private HTTP traffic in-process" case.

| # | API                                        | Purpose                                                                    | Done |
| - | ------------------------------------------ | -------------------------------------------------------------------------- | ---- |
| 1 | Upgrade `tailscale.com` pin                 | Audit upstream changelog between pinned version and latest stable; fold new `ipn.ServeConfig` fields into our model       | [ ]  |
| 2 | `ServeConfig` value type                   | Full Dart mirror of `ipn.ServeConfig`: TCP handlers, web handlers, Funnel enablement per port, `Services`, `AllowFunnel`, `Foreground`, `ETag` | [ ]  |
| 3 | `serve.getConfig()` → `ServeConfig`         | Current serve config (populates ETag)                                      | [ ]  |
| 4 | `serve.setConfig(config)`                   | Replace config atomically; throws on ETag mismatch                         | [ ]  |
| 5 | `TailscaleConflictException`                | Thrown when `setConfig` detects a concurrent modification                  | [ ]  |
| 6 | `tcp.listenService(name, mode)`             | Direct Dart mirror of `tsnet.Server.ListenService` for advertising Tailscale Services hosts. Depends on bumping `tailscale.com` to a release that includes `ListenService` (added upstream in `v1.94.1`). Keep this under `tcp`; do not create a speculative `services` namespace for a single listener primitive. | [ ]  |

**Note on Services:** `Services` / `AllowFunnel` / `Foreground` are
fields in `ipn.ServeConfig`, not a separate product surface — they live
in this namespace, not in a new `services` namespace. `ListenService`
(upstream's `tsnet.Server.ListenService`) is already a separate stable
method; treat it as a transport-aligned listener that belongs under
`tcp`, not as justification for a separate `services` namespace.

**Non-goal for this phase:** no large Dart-side builder / mutator DSL
unless raw `getConfig` / `setConfig` proves too awkward in practice.

**Exit criteria:** e2e publishes a static directory at `/docs/` via
`serve.setConfig` and fetches it back over HTTPS. Live-tailnet only —
Headscale doesn't support Serve/Funnel as of April 2026.

---

### Phase 10 — Escape hatch + polish

**Goal:** ship v1.0 for the core embedding story. Give power users +
third-party extensions a way to reach LocalAPI endpoints we haven't
typed. Regenerate docs.

**Dependencies:** core path only: Phases 1-6. Optional Phases 7-9 can
land before or after v1.0 without changing the core ship criteria.

| # | Item                                                     | Purpose                                                                     | Done |
| - | -------------------------------------------------------- | --------------------------------------------------------------------------- | ---- |
| 1 | `Tailscale.localApi.request(method, path, {body})`       | Generic LocalAPI RPC. Go-side wraps `local.Client.DoLocalRequest`; Dart exposes a minimal `{statusCode, bytes}`-returning shape. **Not** a raw loopback HTTP server (upstream advises against exposing `Loopback()` when `LocalClient` will do). Covers endpoints we haven't typed yet (drive shares, arbitrary DNS queries, debug actions). | [ ]  |
| 2 | `/example/tcp_echo.dart`                                 | Raw-TCP demo                                                                | [x]  |
| 3 | `/example/exit_node.dart`                                | Exit-node selection demo                                                    | [ ]  |
| 4 | README namespace-by-namespace tour                       | Top-level doc update                                                        | [x]  |
| 5 | Full dartdoc regeneration                                | Publish `dartdoc`                                                           | [ ]  |
| 6 | Lock public API for v1.0                                 | Post-v1.0 breaking changes require deprecation cycle                        | [ ]  |
| 7 | Optional examples (`taildrop`, `serve`)                  | Only if the corresponding optional phase lands before v1.0                  | [ ]  |

---

## Release checkpoints

| Version | Phases included                   | User-visible capability                                                    |
| ------- | --------------------------------- | -------------------------------------------------------------------------- |
| v0.3    | 1                                 | Namespaced API shape; no functional change                                 |
| v0.4    | 2 + 4                             | Hygiene fixes (incl. interactive login via new `up()` semantics) + LocalAPI one-shots (whois, diag, ping) |
| v0.5    | 3                                 | Raw TCP                                                                    |
| v0.6    | 5 + 6                             | Remaining advanced/core-adjacent transports (TLS/UDP/Funnel thin surface) + prefs + exit node |
| v1.0    | 10 + core path                    | Core embedding story: lifecycle, private HTTP/TCP, identity/diagnostics, advanced prefs/exit-node controls, LocalAPI escape hatch, docs, API lock |
| post-v1 | 7 + 8 + 9                         | Optional: Profiles, Taildrop, raw Serve config                             |

---

## Testing matrix

Headscale covers most of the surface but not all of it. Phases that
exercise Headscale-unsupported features need a separate path.

| Namespace / feature              | Headscale (CI PR) | Live Tailscale (scheduled, opt-in) |
| -------------------------------- | ----------------- | ---------------------------------- |
| `up` / `down` / `logout`          | ✅                | ✅                                 |
| `tcp.dial` / `tcp.bind`           | ✅                | ✅                                 |
| `udp.bind`                        | ✅                | ✅                                 |
| `http.client` / `http.bind`       | ✅                | ✅                                 |
| `whois`, `diag.ping`, `diag.metrics`, `diag.derpMap` | ✅                | ✅                                 |
| `prefs.*` (subnet routes, shields)| ✅                | ✅                                 |
| `exitNode.*`                      | ✅                | ✅                                 |
| `taildrop.*`                      | ✅                | ✅                                 |
| `profiles.*`                      | ✅                | ✅                                 |
| `tls.bind` / `tls.domains`        | ❌ (no HTTPS)     | ✅                                 |
| `funnel.bind`                     | ❌ (no Funnel)    | ✅                                 |
| `serve.*`                         | ❌ (no Serve)     | ✅                                 |

**Implementation.** Tests reaching Headscale-unsupported features are
tagged `@Tags(['live-tailscale'])` and gated on a `TAILSCALE_AUTHKEY`
env var. PR CI runs untagged tests. A scheduled CI job (or manual
trigger) runs the tagged set against a real Tailscale tailnet using a
service-account reusable preauth key.

**Exit criteria in later phases distinguish the two buckets**
explicitly. If Phase 9 "passes CI" but nobody's run the live-tailscale
job, that's not shippable.

---

## Open design questions

Flagged for resolution in each phase's PR rather than pre-decided.

1. ~~**Value-type equality implementation.**~~ ✅ **Closed:** hand-rolled, no dependency. Zero runtime cost, no codegen, fine for ~13 small value types.
2. **DERP vs Relay naming.** `DERPMap` / `DERPRegion` match upstream exactly but are jargony; `RelayMap` / `RelayRegion` are self-describing but diverge. *Leaning toward keeping DERP to match upstream.* *Decide in Phase 4.*
3. **Namespace constructor visibility pattern.** Private `_(worker)` constructor, `@internal` annotation, `part of`, or explicit doc-only convention? *Decide in Phase 2; apply uniformly.*
4. ~~**`http.bind` local port shape.**~~ ✅ **Closed:** v1 does not expose a `localPort`; inbound HTTP is package-native and accepts tailnet requests directly via `TailscaleHttpServer.requests`.
5. **Funnel metadata lifecycle.** Once Phase 5 chooses the Funnel listener/request surface, decide where public source/SNI metadata lives and when it is cleared.

---

## Future considerations

Not acting on these in this RFC, but worth tracking:

- **`libtailscale`.** Tailscale now publishes a C library for
  embedding Tailscale in-process. Not yet stable enough to justify
  pivoting away from our CGO-export shim, but if it stabilizes it
  could shrink the Go-export surface by ~80% and let us drop
  `go/cmd/dylib/main.go` entirely. Re-evaluate in ~6 months.
- **Upstream feature drift.** `tsnet` and LocalAPI continue to grow
  after the repo's current `tailscale.com v1.92.2` pin. Re-check
  `ListenService`, `ServeConfig`, profile APIs, and taildrop flows
  before each feature phase starts rather than assuming the old model is
  still current.
- **Platform-specific features.** Linux posture checks, Android
  connectivity-migration hooks, iOS background-tunnel APIs —
  platform-gated, should slot into the relevant namespace when
  demand surfaces.
- **Admin REST API.** Tailscale's admin plane (ACL editing, device
  list management) is a separate HTTP API, not LocalAPI. Out of
  scope for this library; a separate `package:tailscale_admin`
  would make sense if we ever go there.

---

## Migration / compatibility

- **Breaking changes concentrated in Phase 1.** Two renames:
  `Tailscale.http` → `Tailscale.http.client`, `Tailscale.listen` →
  `Tailscale.http.bind`. Documented in `CHANGELOG.md`. No
  deprecation shims — the package is pre-1.0 and the user has
  indicated breaking changes are acceptable here.
- **Phase 2 renames are additive** except for `MaskedPrefs` →
  `PrefsUpdate` (pre-1.0, no shim), and adjustments to
  `exitNode.use` signature (there's no existing `exitNode` API to
  break).
- **v1.0 locks the surface.** Any post-v1.0 breaking change requires
  a deprecation cycle of at least one minor release.

---

## Feedback

- Comment inline on the checklist items if a particular method name
  or signature is wrong.
- Open an issue for design-question pushback or additional namespace
  proposals.
- The dependency graph and phase order are intentionally flexible in
  the middle — phases 5–9 can reorder based on user demand, as long
  as their prerequisites are met.
