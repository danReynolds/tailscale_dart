# RFC: Namespaced API for `package:tailscale`

**Status:** Draft — feedback welcome
**Branch:** `api-namespacing`
**Supersedes:** ad-hoc flat API surface on `Tailscale`

---

## Summary

Reorganize the public API of `package:tailscale` from a flat surface on
a single `Tailscale` class into topic-scoped namespaces
(`tsnet.tcp`, `tsnet.http`, `tsnet.taildrop`, `tsnet.serve`, etc.), add
the Tailscale capabilities we've been missing (raw TCP, UDP, TLS,
Funnel, Taildrop, Serve, Exit Node, Profiles, Prefs, diagnostics), and
clean up API-hygiene issues surfaced in design review.

Strict ordering: **parity with today first**, hygiene second, new
capabilities third.

---

## Motivation

Our current public surface is ~10 methods on one class. To close
feature gaps against `tsnet.Server` + `local.Client` we need 50+ new
methods. Putting all of those flat on `Tailscale` sprawls the class
past what IDE autocomplete handles sensibly. Namespacing bounds the
surface per topic and matches both Tailscale's Go structure
(`tsnet.Server`, `local.Client`) and Dart conventions (`dart:io`
`ServerSocket.bind`, `package:http` `Client`).

Separately, design review surfaced API-hygiene issues that will bite
users at runtime (non-nullable lookups, stringly-typed exit-node
handles, missing value-type equality). Those get fixed in one sweep
alongside the namespacing work so every downstream phase lands on a
clean foundation.

---

## Non-goals

Explicitly out of scope for this RFC:

- Replacing or reimplementing `tsnet` — we remain a wrapper.
- Exposing Tailscale admin-plane APIs (ACL editing, device management).
  Those go through the admin REST API, not LocalAPI.
- Reimplementing Tailscale Drive (filesystem shares) in Dart. If a user
  wants it, they can hit the LocalAPI escape hatch (Phase 10).
- Changing any Go-side behavior beyond wrapping. No forking tsnet.

---

## Design principles

These rules apply across every phase. Deviations are called out in doc
comments.

1. **Return standard `dart:io` types** for network primitives
   (`Socket`, `ServerSocket`, `RawDatagramSocket`, `SecureServerSocket`).
   No `Tailscale*Socket` wrappers; no API-level divergence from
   `dart:io`.
2. **One namespace per topic.** A topic earns a namespace at ≥2
   related methods, or 1 method with a cohesive noun (e.g. `udp`).
   Single-method cross-cutting utilities stay flat on `Tailscale`
   (`whois`).
3. **Verb conventions.**
   - `dial` for outbound — mirrors Go (`tsnet.Server.Dial`).
   - `bind` for inbound — mirrors Dart (`ServerSocket.bind`). Avoids
     the collision `.listen(...)` has with `Stream.listen`.
4. **Value types are immutable** with `==`, `hashCode`, `toString`.
5. **Nullable returns** for operations that can legitimately not find
   a thing. Exceptions are for misuse, not missing data.
6. **Per-namespace error classes.** `TailscaleTaildropException`, etc.
   Callers pattern-match on type, not string.
7. **Identity by stable ID, not key material.** Public keys rotate on
   reinstall; `StableNodeID` / `PeerStatus` references don't.

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
Phase 2 (hygiene) ────┬─── Phase 6 (prefs + exitNode)
   │                   ├─── Phase 7 (profiles)
   │                   └─── Phase 9 (serve)
   │
   ├── Phase 3 (bridge + tcp) ──┬── Phase 5 (tls / udp / funnel)
   │                            └── Phase 8 (taildrop)
   │
   └── Phase 4 (LocalAPI one-shots)
                │
           all phases  ───── Phase 10 (escape hatch + polish → v1.0)
```

---

### Phase 1 — Functional parity with today

**Goal:** every existing caller migrates to the namespaced shape with
zero functional regression. No new capabilities exposed.

**Dependencies:** none.

| # | API                                      | Purpose                                                                  | Done |
| - | ---------------------------------------- | ------------------------------------------------------------------------ | ---- |
| 1 | `Tailscale.init({stateDir, logLevel})`    | One-time lib configuration at app startup                                | [ ]  |
| 2 | `Tailscale.up({hostname, authKey, controlUrl})` | Start engine; connect to control plane                             | [ ]  |
| 3 | `Tailscale.down()`                        | Stop engine; keep persisted credentials                                  | [ ]  |
| 4 | `Tailscale.logout()`                      | Stop engine; wipe persisted credentials                                  | [ ]  |
| 5 | `Tailscale.status()`                      | Snapshot of node state + IPs + health                                    | [ ]  |
| 6 | `Tailscale.peers()`                       | Current peer inventory                                                   | [ ]  |
| 7 | `Tailscale.onStateChange`                 | Stream of NodeState transitions (distinct-filtered)                      | [ ]  |
| 8 | `Tailscale.onError`                       | Stream of background runtime errors                                      | [ ]  |
| 9 | `Tailscale.http.client` *(was `.http`)*   | Pre-configured `http.Client` that routes via tailnet                     | [ ]  |
| 10| `Tailscale.http.expose(local, tailnet)` *(was `.listen`)* | Reverse-proxy helper for existing local HTTP servers | [ ]  |
| 11| Migration: `example/example.dart`          | Update to new API surface                                                | [ ]  |
| 12| Migration: `test/e2e/peer_main.dart`       | Update to new API surface                                                | [ ]  |
| 13| Migration: `test/e2e/e2e_test.dart`        | Update to new API surface                                                | [ ]  |
| 14| Migration: `test/ffi_integration_test.dart`| Update to new API surface                                                | [ ]  |
| 15| Migration: `CHANGELOG.md`                  | Document breaking renames                                                | [ ]  |

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
| 1 | `==` / `hashCode` / `toString` on value types           | Hand-rolled equality + debuggability. Covers TailscaleStatus, PeerStatus, PeerIdentity, WaitingFile, FileTarget, LoginProfile, PingResult, DERPMap/Region/Node, ClientVersion, TailscalePrefs, PrefsUpdate, FunnelMetadata | [ ]  |
| 2 | Add `stableNodeId` to `PeerStatus`                       | Upstream `ipnstate.PeerStatus` has `ID tailcfg.StableNodeID`; we dropped it. Required for type-safe `exitNode.use(peer)` | [ ]  |
| 3 | `Tailscale.whois(ip)` returns `Future<PeerIdentity?>`   | Unknown IP returns null instead of forcing try/catch                                | [ ]  |
| 4 | `profiles.current()` returns `Future<LoginProfile?>`    | Fresh install has no current profile — express it in the type                        | [ ]  |
| 5 | `Tailscale.up()` returns `Future<TailscaleStatus>`, resolving on **first stable state only** | Resolves on `running`, `needsLogin`, or `needsMachineAuth`. Caller inspects `status.state` + `authUrl` to route next (interactive login, admin approval, or proceed). **Diverges from Go's `tsnet.Server.Up` which waits only on Running** — intentional; a Dart app can't hang until a human clicks a browser link. If startup fails or the implementation gives up waiting before a stable state is reached, throw `TailscaleUpException`; never return a transitional state such as `starting`. | [ ]  |
| 6 | Prefs setter naming: all `set*` prefix                  | `setAdvertisedRoutes`, `setAcceptRoutes`, `setShieldsUp`, `setAutoUpdate`           | [ ]  |
| 7 | `taildrop.get` → `taildrop.openRead` + `Stream<Uint8List>` | Matches `File.openRead`; efficient byte streaming                                | [ ]  |
| 8 | `exitNode.use(PeerStatus peer)`                         | Type-safe exit-node selection                                                       | [ ]  |
| 9 | `exitNode.useById(String stableNodeId)`                 | Escape hatch when only the stable ID is available                                   | [ ]  |
| 10| Rename `MaskedPrefs` → `PrefsUpdate`                    | Less jargony than the Go term                                                       | [ ]  |
| 11| Structured error fields on all `TailscaleOperationException` subclasses | Add `code: TailscaleErrorCode` (notFound / forbidden / conflict / preconditionFailed / featureDisabled / unknown), `int? statusCode`, `Object? cause`. Go-side translates `IsAccessDeniedError`, `IsPreconditionsFailedError`, HTTP status codes. | [ ]  |
| 12| `TailscaleTaildropException`                            | Per-namespace error type                                                            | [ ]  |
| 13| `TailscaleServeException`                               | Per-namespace error type                                                            | [ ]  |
| 14| `TailscalePrefsException`                               | Per-namespace error type                                                            | [ ]  |
| 15| `TailscaleProfilesException`                            | Per-namespace error type                                                            | [ ]  |
| 16| `TailscaleExitNodeException`                            | Per-namespace error type                                                            | [ ]  |
| 17| `TailscaleDiagException`                                | Per-namespace error type                                                            | [ ]  |
| 18| Namespace constructors private                          | `Tcp._(worker)` etc., so users can't create unbound instances                       | [ ]  |

**Exit criteria:**

- Every value type has equality tests (`test/equality_test.dart`).
- Public API surface locked — no renames past this point without a
  deprecation cycle.

---

### Phase 3 — Loopback bridge + `tcp` primitives

**Goal:** enable non-HTTP peer communication. Establishes the Go-side
foundation every socket-shaped API depends on, without weakening the
`dart:io` socket contract the Dart surface promises.

**Dependencies:** Phase 2 (data-type shapes must be settled for error
returns).

| # | API                                                     | Purpose                                                                              | Done |
| - | ------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---- |
| 1 | Go: `bridgeTCPToLoopback(net.Conn) → (port, token)`     | One-shot loopback bridge helper; reusable across TLS/Funnel/Taildrop                 | [ ]  |
| 2 | Go FFI: `DuneTcpDial(host, port) → {port, token}`       | Outbound dial entry point                                                            | [ ]  |
| 3 | Go FFI: `DuneTcpBind(port, host) → {acceptPort, token}` | Inbound bind entry point                                                             | [ ]  |
| 4 | `tcp.dial(host, port, {timeout})` → `Future<Socket>`    | Open TCP connection to a tailnet peer; wraps `tsnet.Server.Dial`                     | [ ]  |
| 5 | `tcp.bind(port, {host})` → `Future<ServerSocket>`       | Accept TCP connections on the tailnet; wraps `tsnet.Server.Listen("tcp", ...)`       | [ ]  |
| 6 | Per-dial auth token                                     | Loopback port is auth-gated so co-resident processes can't hijack                    | [ ]  |
| 7 | Bridge preserves TCP half-close semantics               | One side reaching EOF closes only that write direction; the opposite direction remains readable/writable until it closes too. Use `CloseWrite` / `CloseRead` (or the closest available platform equivalent) instead of unconditional full-close on first `io.Copy` completion. | [ ]  |
| 8 | Listener is truly single-use                            | The loopback listener closes immediately after the first successful `Accept`, regardless of how long the proxied session lives, so later local connects cannot race a dead bridge. | [ ]  |
| 9 | Timeout contract is explicit and tested                 | `tcp.dial(timeout: X)` must document and enforce one timeout model. Preferred contract: one end-to-end budget spanning tailnet dial, loopback connect, and token handshake, rather than reusing `X` independently at each stage. | [ ]  |
| 10| **Platform verification: iOS + Android**                | Confirm the loopback-bridge helper works under the existing native-assets hook on both mobile platforms. If loopback binding is kernel-gated on iOS in a way that blocks this pattern, that needs to surface here — not in Phase 5 when three transports are downstream. | [ ]  |
| 11| E2E byte-echo test                                      | Two nodes exchange arbitrary bytes via `tcp.dial` + `tcp.bind`                       | [ ]  |
| 12| Go regression tests for bridge invariants               | Cover token rejection, accept-timeout cleanup, half-close propagation, and single-use listener behavior under second-connector contention. | [ ]  |
| 13| Example: raw-TCP echo server/client                     | `/example/tcp_echo.dart`                                                             | [ ]  |

**Exit criteria:**

- `dart test test/e2e/e2e_test.dart` passes a new `tcp lifecycle`
  group with byte-level assertions.
- Go tests cover token rejection, accept-timeout cleanup,
  half-close propagation, and listener single-use behavior.
- The timeout contract is documented in Dart doc comments and matched
  by tests; `tcp.dial(timeout: X)` must not silently take ~2x `X`
  unless the docs explicitly define timeout as per-stage rather than
  end-to-end.

---

### Phase 4 — LocalAPI one-shots

**Goal:** expose the read-only and simple-write LocalAPI calls that
don't require the loopback bridge. Proceeds in parallel with Phase 3.

**Dependencies:** Phase 2.

Note: the interactive-login flow previously listed here is folded into
Phase 2's new `up()` semantics — a no-authKey `up()` on a fresh dir now
resolves with `status.state == needsLogin` and a populated `authUrl`.
No separate work item.

| # | API                                            | Purpose                                                                         | Done |
| - | ---------------------------------------------- | ------------------------------------------------------------------------------- | ---- |
| 1 | `Tailscale.whois(ip)` → `PeerIdentity?`        | Identify a tailnet IP's owner / hostname / tags                                  | [ ]  |
| 2 | `Tailscale.onPeersChange` → `Stream<List<PeerStatus>>` | React to peer inventory changes without polling                          | [ ]  |
| 3 | `diag.ping(ip, {timeout, type})` → `PingResult`| Round-trip + direct-vs-DERP diagnostic; accepts MagicDNS names                   | [ ]  |
| 4 | `diag.metrics()` → `String`                    | Prometheus-format metrics snapshot from the embedded runtime                     | [ ]  |
| 5 | `diag.derpMap()` → `DERPMap`                   | Current relay region + node map                                                  | [ ]  |
| 6 | `diag.checkUpdate()` → `ClientVersion?`        | Latest tsnet version if newer than embedded, else null                           | [ ]  |
| 7 | `tls.domains()` → `List<String>`               | Cert SANs; preflight for `tls.bind`                                              | [ ]  |

**Exit criteria:** each method has a unit test; e2e covers the happy
path for each diagnostic.

---

### Phase 5 — Remaining transports

**Goal:** apply the Phase 3 bridge pattern to the remaining
transports.

**Dependencies:** Phase 3.

| # | API                                                          | Purpose                                                                   | Done |
| - | ------------------------------------------------------------ | ------------------------------------------------------------------------- | ---- |
| 1 | `tls.bind(port)` → `Future<SecureServerSocket>`              | TLS-terminated listener with auto-provisioned cert                        | [ ]  |
| 2 | UDP datagram bridge variant                                  | Frame `[peerIP, peerPort, payload]` envelopes over loopback               | [ ]  |
| 3 | `udp.bind(host, port)` → `Future<RawDatagramSocket>`         | UDP datagram listener on a specific tailnet IP                             | [ ]  |
| 4 | `funnel.bind(port, {funnelOnly})` → `Future<SecureServerSocket>` | Public-internet HTTPS via Funnel. **Returns a standard `SecureServerSocket`**; Funnel-specific metadata is accessible via extension (see next row). | [ ]  |
| 5 | `FunnelMetadata` + `Socket.funnel` extension                 | Expose original public-client source IP + SNI target without breaking the "standard `dart:io` types" principle. Internal `Expando<FunnelMetadata>` keyed by `Socket`; extension getter resolves it. Non-Funnel sockets return null. | [ ]  |
| 6 | Example: all-transports demo                                 | `/example/transports.dart` exercising TCP + TLS + UDP + Funnel            | [ ]  |

**Exit criteria:** demo runs against a live tailnet; CI e2e covers
each transport. Funnel/TLS tests are opt-in (see Testing matrix below)
since Headscale doesn't support them.

---

### Phase 6 — Prefs + Exit Node

**Goal:** advanced routing config. First API surface that writes state
beyond the engine lifecycle.

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
| 8 | `exitNode.current()` → `PeerStatus?`                       | Peer currently being used as exit, or null                              | [ ]  |
| 9 | `exitNode.suggest()` → `PeerStatus?`                       | Control-plane-recommended exit node (latency-based)                     | [ ]  |
| 10| `exitNode.use(PeerStatus)`                                 | Route all outbound traffic through this peer                            | [ ]  |
| 11| `exitNode.useById(String stableNodeId)`                    | Same as `use`, but for the case where only the stable ID is known       | [ ]  |
| 12| `exitNode.useAuto()`                                       | Set `AutoExitNode` / `auto:any` mode — let the control plane pick. Upstream prefs support this; future-proofs the API against requiring a user-facing "auto" button to land as a breaking redesign. | [ ]  |
| 13| `exitNode.clear()`                                         | Stop routing through an exit node                                        | [ ]  |
| 14| `exitNode.onCurrentChange` → `Stream<PeerStatus?>`         | React to exit-node changes (including external)                          | [ ]  |

**Exit criteria:** e2e covers advertising a route, using/clearing an
exit node (manual + auto), and shields-up behavior.

---

### Phase 7 — Profiles

**Goal:** multi-account / multi-tailnet support — one device, several
identities.

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

### Phase 8 — Taildrop

**Goal:** peer-to-peer file transfer.

**Dependencies:** Phase 3 or an equivalent LocalAPI-backed
byte-stream path.

Taildrop should follow the simplest stream-safe implementation path
available at the time. If LocalAPI-backed streaming lands cleanly
before the general socket bridge is mature enough, Taildrop can move
earlier rather than waiting on unrelated transport work.

| # | API                                                                      | Purpose                                                                                     | Done |
| - | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ---- |
| 1 | `taildrop.targets()` → `List<FileTarget>`                                | Peers you can send files to right now                                                       | [ ]  |
| 2 | `taildrop.push({target, name, data, size?})`                             | Stream a file to a peer                                                                      | [ ]  |
| 3 | `taildrop.waitingFiles()` → `List<WaitingFile>`                          | Files received and not yet picked up                                                         | [ ]  |
| 4 | `taildrop.awaitWaitingFiles({timeout})` → `List<WaitingFile>`            | Block until at least one file is available, or timeout                                      | [ ]  |
| 5 | `taildrop.openRead(name)` → `Stream<Uint8List>`                          | Stream a received file's bytes (caller owns persistence)                                     | [ ]  |
| 6 | `taildrop.delete(name)`                                                  | Discard a received file without reading                                                      | [ ]  |
| 7 | `taildrop.onWaitingFile` → `Stream<WaitingFile>`                         | Reactive version of `awaitWaitingFiles`                                                      | [ ]  |
| 8 | E2E file-roundtrip test                                                  | Two nodes push / receive a file with checksum verification                                  | [ ]  |

**Exit criteria:** e2e sends a 1MB file end-to-end and verifies bytes
on both sides.

---

### Phase 9 — Serve

**Goal:** programmatic access to what `tailscale serve` / `tailscale
funnel` do on the CLI.

**Dependencies:** Phase 2. **Also:** upgrade `tailscale.com` Go module
pin to the latest stable at the time Phase 9 starts (current pin
`v1.92.2` is missing `Services`, `AllowFunnel`, `Foreground`,
`ListenService`, and per-service ETag introduced in later upstream
versions). Bump + audit the diff before modelling `ServeConfig`.

| # | API                                        | Purpose                                                                    | Done |
| - | ------------------------------------------ | -------------------------------------------------------------------------- | ---- |
| 1 | Upgrade `tailscale.com` pin                 | Audit upstream changelog between pinned version and latest stable; fold new `ipn.ServeConfig` fields into our model       | [ ]  |
| 2 | `ServeConfig` value type                   | Full Dart mirror of `ipn.ServeConfig`: TCP handlers, web handlers (path mounts, static roots, reverse-proxy targets), Funnel enablement per port, `Services`, `AllowFunnel`, `Foreground`, `ETag` | [ ]  |
| 3 | `ServeConfig.addWebMount(path, handler)`    | Immutable mutator — add a web path handler                                 | [ ]  |
| 4 | `ServeConfig.removeWebMount(path)`          | Immutable mutator — remove a web path handler                              | [ ]  |
| 5 | `ServeConfig.addTcpHandler(port, handler)`  | Immutable mutator — route a TCP port                                       | [ ]  |
| 6 | `ServeConfig.enableFunnel(port, {handlers})`| Immutable mutator — toggle Funnel on a port                                | [ ]  |
| 7 | `ServeConfig.setService(service, config)`   | Immutable mutator — add/update a virtual service entry                     | [ ]  |
| 8 | `serve.getConfig()` → `ServeConfig`         | Current serve config (populates ETag)                                      | [ ]  |
| 9 | `serve.setConfig(config)`                   | Replace config atomically; throws on ETag mismatch                         | [ ]  |
| 10| `TailscaleConflictException`                | Thrown when `setConfig` detects a concurrent modification                  | [ ]  |

**Note on Services:** `Services` / `AllowFunnel` / `Foreground` are
fields in `ipn.ServeConfig`, not a separate product surface — they live
in this namespace, not in a new `services` namespace. `ListenService`
(upstream's `tsnet.Server.ListenService`) is a separate method; if/when
it stabilizes, slot it under `tcp` or a future phase. Don't create a
speculative `services` namespace.

**Exit criteria:** e2e publishes a static directory at `/docs/` via
`serve.setConfig` and fetches it back over HTTPS. Live-tailnet only —
Headscale doesn't support Serve/Funnel as of April 2026.

---

### Phase 10 — Escape hatch + polish

**Goal:** ship v1.0. Give power users + third-party extensions a way
to reach LocalAPI endpoints we haven't typed. Regenerate docs.

**Dependencies:** all prior phases.

| # | Item                                                     | Purpose                                                                     | Done |
| - | -------------------------------------------------------- | --------------------------------------------------------------------------- | ---- |
| 1 | `Tailscale.localApi.request(method, path, {body})`       | Generic LocalAPI RPC. Go-side wraps `local.Client.DoLocalRequest`; Dart exposes a minimal `{statusCode, bytes}`-returning shape. **Not** a raw loopback HTTP server (upstream advises against exposing `Loopback()` when `LocalClient` will do). Covers endpoints we haven't typed yet (drive shares, arbitrary DNS queries, debug actions). | [ ]  |
| 2 | `/example/tcp_echo.dart`                                 | Raw-TCP demo                                                                | [ ]  |
| 3 | `/example/taildrop.dart`                                 | Taildrop send/receive demo                                                  | [ ]  |
| 4 | `/example/serve.dart`                                    | Serve config demo                                                           | [ ]  |
| 5 | `/example/exit_node.dart`                                | Exit-node selection demo                                                    | [ ]  |
| 6 | README namespace-by-namespace tour                       | Top-level doc update                                                        | [ ]  |
| 7 | Full dartdoc regeneration                                | Publish `dartdoc`                                                           | [ ]  |
| 8 | Lock public API for v1.0                                 | Post-v1.0 breaking changes require deprecation cycle                        | [ ]  |

---

## Release checkpoints

| Version | Phases included                   | User-visible capability                                                    |
| ------- | --------------------------------- | -------------------------------------------------------------------------- |
| v0.3    | 1                                 | Namespaced API shape; no functional change                                 |
| v0.4    | 2 + 4                             | Hygiene fixes (incl. interactive login via new `up()` semantics) + LocalAPI one-shots (whois, diag, ping) |
| v0.5    | 3 + 5                             | Full transport surface (raw TCP, TLS, UDP, Funnel)                         |
| v0.6    | 6                                 | Prefs + exit node                                                          |
| v0.7    | 7 + 8                             | Profiles + Taildrop                                                        |
| v0.8    | 9                                 | Serve                                                                      |
| v1.0    | 10                                | Escape hatch + docs + API lock                                             |

---

## Testing matrix

Headscale covers most of the surface but not all of it. Phases that
exercise Headscale-unsupported features need a separate path.

| Namespace / feature              | Headscale (CI PR) | Live Tailscale (scheduled, opt-in) |
| -------------------------------- | ----------------- | ---------------------------------- |
| `up` / `down` / `logout`          | ✅                | ✅                                 |
| `tcp.dial` / `tcp.bind`           | ✅                | ✅                                 |
| `udp.bind`                        | ✅                | ✅                                 |
| `http.client` / `http.expose`     | ✅                | ✅                                 |
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
4. **`http.expose` ephemeral port.** Today's `listen()` supports `localPort: 0` → ephemeral allocation, returns the port. Keep or require non-zero? *Decide in Phase 1.*
5. **Funnel metadata registry lifecycle.** `Expando<FunnelMetadata>` keyed by `Socket` — when does the entry get cleared? On socket close (via listener), or garbage-collected with the socket? If the former, need a `Socket.done` hook or similar. *Decide in Phase 5.*

---

## Future considerations

Not acting on these in this RFC, but worth tracking:

- **`libtailscale`.** Tailscale now publishes a C library for
  embedding Tailscale in-process. Not yet stable enough to justify
  pivoting away from our CGO-export shim, but if it stabilizes it
  could shrink the Go-export surface by ~80% and let us drop
  `go/cmd/dylib/main.go` entirely. Re-evaluate in ~6 months.
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
  `Tailscale.http.expose`. Documented in `CHANGELOG.md`. No
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
