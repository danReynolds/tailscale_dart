# API Namespacing Roadmap

Working document for the `api-namespacing` branch. Tracks the move from
today's flat API on `Tailscale` to a namespaced shape, and enumerates
the new capabilities we want to add along the way.

**Priority ordering, strictly:**

1. **Functional parity with today.** No user who relies on the current
   API may regress.
2. **API-hygiene fixes** from design review (value-type equality,
   nullable returns, naming consistency, etc.).
3. **New network primitives** (`tcp.dial`, `tcp.bind`, `tls`, `udp`,
   `funnel`) — unblocks non-HTTP peer communication.
4. **New feature clusters** (`taildrop`, `serve`, `exitNode`, `profiles`,
   `prefs`, `diag`) — product surface area.

---

## Design principles

The API should obey these rules consistently. Deviations get called out
in code comments.

1. **Return standard `dart:io` types** for network primitives (`Socket`,
   `ServerSocket`, `RawDatagramSocket`, `SecureServerSocket`). A
   developer who knows `dart:io` should not need to learn new wrappers.
2. **One namespace per topic.** A topic earns a namespace at ≥2 related
   methods, or 1 method with a cohesive noun (e.g. `udp`). Single-method
   unrelated utilities stay flat on `Tailscale` (e.g. `whois`).
3. **Verb conventions:**
   - `dial` for outbound — mirrors Go / tsnet `Server.Dial`.
   - `bind` for inbound — mirrors `dart:io` `ServerSocket.bind`. Avoids
     the collision `.listen(...)` has with `Stream.listen(callback)`.
4. **Value types are immutable** with `==`, `hashCode`, `toString`. Use
   `package:meta` `@immutable` and hand-rolled equality (or codegen).
5. **Nullable returns** for operations that can legitimately not find a
   thing (`whois`, `profiles.current`, `diag.checkUpdate`). Exceptions
   are for misuse, not missing data.
6. **Per-namespace error classes.** `TailscaleTaildropException`,
   `TailscaleServeException`, `TailscalePrefsException`, etc. Catchers
   can pattern-match on type, not string.
7. **Identity by stable ID, not key material.** Exit node selection,
   profile switching, etc. use `StableNodeID` (Tailscale's term) or
   `PeerStatus` objects, not public keys (which rotate on reinstall).

---

## Phase 1 — Current feature parity

**Goal:** every working caller today migrates to the new namespace shape
with no functional regression. Nothing new exposed in this phase.

**Scope:**

- Wire `Tailscale.http.client` to the existing `TailscaleProxyClient`
  created in `up()`.
- Wire `Tailscale.http.expose(localPort, {tailnetPort})` to the existing
  `Worker.listen(...)`.
- Keep `Tailscale.up()` / `down()` / `logout()` / `status()` / `peers()`
  / `onStateChange` / `onError` exactly as-is behaviorally.
- All other namespaces stay `throw UnimplementedError`.
- Update callers (`example/`, `test/e2e/peer_main.dart`, both test
  suites) — already done in the stub commit.
- `CHANGELOG.md` entry listing the renames.

**Non-goals:** new functionality, data-type hygiene work, any tsnet
changes.

**Dependencies:** none. The stub branch's structure + the existing Go
code is all we need.

**Effort:** ~½ day.

**Exit criteria:**

- `dart analyze lib/ test/ hook/ example/` clean.
- `dart test test/tailscale_test.dart test/proxy_client_test.dart` —
  20/20.
- `dart test test/ffi_integration_test.dart` — 29/29.
- `dart test test/e2e/e2e_test.dart` against Headscale — 18/18.
- Example app in `/example/` compiles and exercises the new path.

---

## Phase 2 — Foundation: cross-cutting API hygiene

**Goal:** address every critical/important finding from the design
review in one sweep, so downstream phases don't each re-open the same
debates.

**Scope:**

- **Value-type equality.** Add `@immutable`, `==`, `hashCode`,
  `toString` to: `TailscaleStatus`, `PeerStatus`, `PeerIdentity`,
  `WaitingFile`, `FileTarget`, `LoginProfile`, `PingResult`, `DERPMap`,
  `DERPRegion`, `DERPNode`, `ClientVersion`, `TailscalePrefs`,
  `PrefsUpdate`. Either hand-roll or add `package:equatable` /
  `package:freezed` — decision item in the PR.
- **Nullable returns.**
  - `Tailscale.whois(ip) → Future<PeerIdentity?>`
  - `Tailscale.profiles.current() → Future<LoginProfile?>`
- **`Tailscale.up()` returns `Future<TailscaleStatus>`** instead of
  `Future<void>` — mirrors `tsnet.Server.Up(ctx)`.
- **Prefs setter naming.** All `set*` prefix:
  - `prefs.setAdvertisedRoutes([...])`
  - `prefs.setAcceptRoutes(bool)`
  - `prefs.setShieldsUp(bool)`
  - `prefs.setAutoUpdate(bool)`
  - `prefs.updateMasked(PrefsUpdate)`
- **Taildrop byte streams.** `taildrop.get(name)` →
  `taildrop.openRead(name)` returning `Stream<Uint8List>` (matches
  `File.openRead`).
- **Identity handles.** `exitNode.use(PeerStatus peer)` type-safe form,
  plus `exitNode.useById(String stableNodeId)` escape hatch. Drop
  `publicKey` parameter — keys rotate, stable ID doesn't.
- **Rename `MaskedPrefs` → `PrefsUpdate`** (less jargony).
- **Per-namespace error classes.**
  - `TailscaleTaildropException`
  - `TailscaleServeException`
  - `TailscalePrefsException`
  - `TailscaleProfilesException`
  - `TailscaleExitNodeException`
  - `TailscaleDiagException`
  - Each extends `TailscaleOperationException` with the appropriate
    operation string, preserving existing catch patterns.
- **Namespace constructor privacy.** Move `Tcp()`, `Tls()`, etc. to
  `Tcp._(this._worker)` so users can't construct unbound instances.

**Non-goals:** implementing any of the stubs (that's Phase 3+).

**Dependencies:** Phase 1.

**Effort:** ~1 day.

**Exit criteria:**

- Every value type has a `test/equality_test.dart` entry exercising
  `==` / `hashCode` / `toString`.
- Design-review critical + important findings all closed.
- Public API surface locked; no renames after this without a
  deprecation cycle.

---

## Phase 3 — Loopback bridge + `tcp` primitives

**Goal:** enable non-HTTP peer communication. This is the Go-side
foundation every socket-shaped API depends on, so it unblocks phases 5,
8 when it lands.

**Scope:**

- **Go bridge helper** (`go/bridge.go`):
  ```go
  // Spins up a one-shot 127.0.0.1:0 listener that bridges bytes into
  // tailConn. Returns the loopback port + a per-dial auth token the
  // Dart caller must present (same pattern as today's HTTP proxy).
  func bridgeTCPToLoopback(tailConn net.Conn) (port int, token string, err error)
  ```
- **FFI surface:** `DuneTcpDial(host, port, stateDir) → {port, token}`,
  `DuneTcpBind(tailnetPort, host, stateDir) → {acceptPort, token}`
  (bind's loopback listener streams accepted conns).
- **Dart API:**
  - `tcp.dial(host, port, {timeout}) → Future<Socket>` — connects to
    loopback with the auth token, returns the standard `Socket`.
  - `tcp.bind(port, {host}) → Future<ServerSocket>` — connects accept
    loop to loopback listener, re-exposes as `ServerSocket`.
- **Per-dial auth token** to prevent co-resident processes from
  hijacking the loopback port (same threat model as
  `proxyAuthToken` today).
- **E2E test:** two nodes exchange arbitrary bytes via `tcp.dial` /
  `tcp.bind`.

**Non-goals:** TLS, UDP, Funnel (they reuse the same bridge in later
phases).

**Dependencies:** Phase 2 (data type hygiene doesn't block the bridge
itself, but the value types returned by errors need to be settled).

**Effort:** ~3–4 days. Bridge is the actual work; wiring is fast.

**Exit criteria:**

- E2E byte-echo test between two nodes using raw TCP.
- Example in `/example/` demonstrating peer-to-peer TCP (e.g. an echo
  server + client).

---

## Phase 4 — LocalAPI one-shots (parallel to Phase 3)

**Goal:** expose read-only + simple-write LocalAPI calls that don't
need the loopback bridge. Can proceed independently of Phase 3.

**Scope:**

- `Tailscale.whois(ip) → Future<PeerIdentity?>`
- `Tailscale.onPeersChange` stream (derive from `WatchIPNBus`)
- `diag.ping(ip, {timeout, type}) → Future<PingResult>` — accept
  MagicDNS names, not just IPs.
- `diag.metrics() → Future<String>`
- `diag.derpMap() → Future<DERPMap>`
- `diag.checkUpdate() → Future<ClientVersion?>`
- `tls.domains() → Future<List<String>>`
- **Interactive login flow:** `up()` without authKey on a fresh state
  dir no longer throws — surfaces `NodeState.needsLogin` with
  `authUrl` populated via `onStateChange`. Caller launches the URL in
  a browser; node transitions to `running` on successful login. Needs
  `up()` signature change to not require authKey.

**Non-goals:** transport primitives, feature clusters.

**Dependencies:** Phase 2.

**Effort:** ~2–3 days.

**Exit criteria:**

- Each method has a unit test + one e2e test where applicable.
- Interactive login e2e with Headscale (opens a browser-URL flow in a
  test harness).

---

## Phase 5 — Remaining transports

**Goal:** finish the socket-primitive surface by applying the Phase 3
bridge pattern to the remaining transports.

**Scope:**

- `tls.bind(port) → Future<SecureServerSocket>` — wraps
  `tsnet.Server.ListenTLS`. Same bridge, TLS termination Go-side.
- `udp.bind(host, port) → Future<RawDatagramSocket>` —
  **datagram-flavored bridge variant.** UDP has no connection; need
  framing (`[peerIP, peerPort, payload]` envelopes over loopback).
- `funnel.bind(port, {funnelOnly}) → Future<SecureServerSocket>` —
  wraps `tsnet.Server.ListenFunnel`, same mechanics as `tls.bind`.
- Demo app in `/example/` using all four transports end-to-end
  (including raw TCP from Phase 3).

**Dependencies:** Phase 3.

**Effort:** ~2 days. TCP bridge is reusable; UDP needs framing.

**Exit criteria:**

- Demo app running against a live tailnet.
- E2E coverage for each transport (echo / probe / receive).

---

## Phase 6 — Prefs + Exit Node

**Goal:** advanced routing config — subnet routes, shields up, exit
node selection. First API surface that writes state beyond the auth /
engine lifecycle.

**Scope:**

- `prefs.get() → Future<TailscalePrefs>`
- `prefs.set*()` methods (as enumerated in Phase 2)
- `prefs.updateMasked(PrefsUpdate) → Future<TailscalePrefs>`
- `exitNode.current() → Future<PeerStatus?>`
- `exitNode.suggest() → Future<PeerStatus?>`
- `exitNode.use(PeerStatus peer) → Future<void>`
- `exitNode.useById(String stableNodeId) → Future<void>`
- `exitNode.clear() → Future<void>`
- `exitNode.onCurrentChange → Stream<PeerStatus?>` (derive from IPN bus
  prefs-changed events)

**Dependencies:** Phase 2 (data type hygiene).

**Effort:** ~1½ days.

---

## Phase 7 — Profiles

**Goal:** multi-account / multi-tailnet support.

**Scope:**

- `profiles.current() → Future<LoginProfile?>` (nullable)
- `profiles.list() → Future<List<LoginProfile>>`
- `profiles.switchTo(LoginProfile profile) → Future<void>`
- `profiles.switchToId(String id) → Future<void>` (escape hatch)
- `profiles.delete(LoginProfile profile) → Future<void>`
- `profiles.newEmpty() → Future<void>`

**Dependencies:** Phase 2.

**Effort:** ~1 day.

---

## Phase 8 — Taildrop

**Goal:** peer-to-peer file transfer. Biggest single feature surface,
including byte streaming over FFI.

**Scope:**

- `taildrop.targets() → Future<List<FileTarget>>`
- `taildrop.push({target, name, data: Stream<Uint8List>, size?})`
- `taildrop.waitingFiles() → Future<List<WaitingFile>>`
- `taildrop.awaitWaitingFiles({timeout}) → Future<List<WaitingFile>>`
- `taildrop.openRead(name) → Future<Stream<Uint8List>>`
  (byte streaming via loopback bridge, same mechanism as `tcp.bind`
  accept loop).
- `taildrop.delete(name) → Future<void>`
- `taildrop.onWaitingFile → Stream<WaitingFile>` — loop around
  `awaitWaitingFiles`.

**Dependencies:** Phase 3 (byte-stream bridging pattern).

**Effort:** ~3 days. The bridging work borrows heavily from Phase 3 but
needs additional work for long-poll semantics and arbitrary file sizes.

---

## Phase 9 — Serve

**Goal:** configure tailnet HTTP routing + Funnel publication —
programmatic access to what `tailscale serve` / `tailscale funnel` do
on the CLI.

**Scope:**

- **`ServeConfig` full data model** mirroring `ipn.ServeConfig`:
  - Web handlers (path-level mounts, proxy targets, static directories)
  - TCP handlers (TLS termination, reverse proxy)
  - Funnel enablement per port
  - ETag (for optimistic concurrency)
- `serve.getConfig() → Future<ServeConfig>`
- `serve.setConfig(ServeConfig config) → Future<void>` — throws
  `TailscaleConflictException` on ETag mismatch.
- Convenience builders on `ServeConfig` for common mutations
  (`addWebMount`, `removeWebMount`, `enableFunnelOn443`, etc.).

**Dependencies:** Phase 2.

**Effort:** ~3 days. The data model is ~200 lines of value classes; the
LocalAPI wire-up is small.

---

## Phase 10 — Escape hatch + polish

**Goal:** ship v1.0. Surface anything we haven't wrapped as a raw
LocalAPI client so power users aren't stuck. Regenerate docs.

**Scope:**

- `Tailscale.localApi` returning a minimal HTTP-over-loopback `Client`
  against tsnet's LocalAPI socket. Lets callers hit
  `/localapi/v0/drive-shares`, `/localapi/v0/query-feature`, etc.
  directly without waiting on a typed wrapper.
- One example app per major namespace in `/example/`.
- README overhaul (namespace-by-namespace tour).
- Full dartdoc regeneration.
- Lock the public API; breaking changes post-v1.0 go through a
  deprecation cycle.

**Dependencies:** most phases done.

**Effort:** ~2–3 days.

---

## Dependency graph

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
                │
            [ all phases ] ──── Phase 10 (escape hatch + docs → v1.0)
```

## Effort totals

| Range                                 | Days          |
| ------------------------------------- | ------------- |
| Critical path (Phase 1 → 2)           | ~1½           |
| Parity + basic primitives (→ Phase 3) | ~5            |
| Full transport surface (→ Phase 5)    | ~7            |
| Full feature surface (→ Phase 9)      | ~17           |
| v1.0 (→ Phase 10)                     | ~20           |

## Release checkpoints

- **v0.3:** Phase 1 complete. Namespaced API shape, functional parity.
- **v0.4:** Phase 2 + Phase 4. Hygiene sweep + LocalAPI one-shots.
- **v0.5:** Phase 3 + Phase 5. Full transport surface (tcp, tls, udp,
  funnel).
- **v0.6:** Phase 6. Prefs + exit node.
- **v0.7:** Phase 7 + Phase 8. Profiles + Taildrop.
- **v0.8:** Phase 9. Serve.
- **v1.0:** Phase 10.

## Open design questions

Flagged for resolution in the PR for each phase, not pre-decided here.

1. **Equatable vs freezed vs hand-rolled** for value-type equality
   (Phase 2). Tradeoff: dependency vs codegen complexity vs
   keystrokes.
2. **`DERPMap` naming.** Upstream jargon (`DERP`) vs self-describing
   (`RelayMap`). Upstream is unambiguous if you know Tailscale; the
   latter is kinder to Dart-first readers. No strong opinion; defer
   to Phase 4.
3. **Namespace constructor visibility.** `@internal` annotation vs
   `part of` vs exposed-but-documented-as-internal. Phase 2 decides
   one pattern and applies it to all.
4. **Should `http.expose` support local port = 0 for ephemeral**?
   Today's `listen()` does. Decide in Phase 1 and document the return
   value accordingly.
5. **Interactive login UX** (Phase 4). Do we provide a helper to
   launch the URL, or is that the caller's job? Web/mobile have
   different constraints.
