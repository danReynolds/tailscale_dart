## Unreleased

**Phase 5 — TLS + UDP transports:**

- `tls.bind(port)` → `Future<ServerSocket>` is live. Wraps `tsnet.Server.ListenTLS`; TLS is terminated inside the Go runtime using the node's auto-provisioned Let's Encrypt cert, and Dart handlers receive plaintext `Socket`s. Private key never crosses the FFI boundary. Requires MagicDNS + HTTPS enabled on the tailnet — `tls.domains()` is the preflight; failures surface as `TailscaleTlsException` with `featureDisabled` when either is off.
- `udp.bind(host, port)` → `Future<RawDatagramSocket>` is live. Wraps `tsnet.Server.ListenPacket`. The returned socket genuinely `implements RawDatagramSocket` — `.receive()` yields a `Datagram` whose `.address` is the real tailnet peer IP (100.x / fd7a:), not an opaque loopback mapping. `.send(buffer, tailnetAddr, port)` takes a tailnet destination. Framing is invisible to callers. Multicast and raw socket options throw `UnsupportedError` (genuinely unavailable over the bridge; explicit error beats silent no-op). `host` is required per `tsnet.ListenPacket` semantics — read it off `(await tsnet.status()).ipv4` at call time.
- `example/transports.dart` — runnable demo exercising TCP + TLS + UDP as client/server pairs.

**Breaking — Phase 5 shape changes:**

- `Tls.bind` signature changed from `Future<SecureServerSocket>` to `Future<ServerSocket>`. `SecureServerSocket` is contractually a TLS-terminating listener (`SecurityContext`, peer cert access); our bridge terminates TLS in Go and hands plaintext to Dart. Returning the stricter type would have misled callers about what TLS guarantees Dart has access to. The doc comment on `tls.bind` spells out what terminates where.
- `tls.domains()` failures now throw `TailscaleTlsException` instead of `TailscaleStatusException`. Matches the per-namespace exception pattern used by `tcp` / `taildrop` / `serve` / `prefs` / `profiles` / `exitNode` / `diag` / `http`. Callers that catch on `TailscaleOperationException` (or the `sealed` base `TailscaleException`) are unaffected.
- `Udp.instance` static is removed. `Udp` is now `abstract` with an internal factory wired to the engine; reach it via `Tailscale.instance.udp` as with every other namespace. (The old `Udp.instance` was a const-singleton stub whose only method threw `UnimplementedError`, so direct callers couldn't have been doing anything useful.)

**Internal — Phase 5:**

- New `go/udp.go` with `UdpBind` + framed packet pump; shared `registerInboundBridge` helper extracted from `TcpBind` for the `ListenTLS` path. No separate UDP unbind — bridge conn close is the canonical teardown signal.
- Frame wire format (both directions): `[1 byte addrFam=4|16][4 or 16 bytes IP][2 bytes BE port][2 bytes BE len][payload]`. Roundtrip unit tests in `go/udp_test.go`; parse-time unit tests for the Dart socket in `test/udp_test.dart` using a real connected loopback TCP pair.
- `Udp` namespace refactored from const-singleton to abstract / `_Udp` / factory shape (matching `Tcp` / `Tls` / `Diag`).
- New per-namespace exceptions: `TailscaleTlsException`, `TailscaleUdpException`.

**Phase 4 — LocalAPI one-shots:**

- `Tailscale.whois(ip)` → `Future<PeerIdentity?>` is live. Wraps `local.Client.WhoIs`; 404 from LocalAPI (unknown IP on this tailnet) maps to `null`, other errors throw.
- `Tailscale.onPeersChange` → `Stream<List<PeerStatus>>` is live. The Go-side IPN bus watcher now subscribes to `NotifyInitialNetMap` in addition to `NotifyInitialState`. A NetMap burst is debounced with a 100ms trailing-edge timer before fetching `lc.Status()` and serializing the peer list, so endpoint reshuffles and relay flaps don't produce one publish per tick. Dedup is left to subscribers — pipe through `.distinct()` if you only want real transitions.
- `tls.domains()` → `Future<List<String>>` is live. Reads `lc.Status().CertDomains`; empty list when MagicDNS or HTTPS is disabled on the tailnet.
- `diag.ping(ip, {timeout, type})` → `Future<PingResult>` is live. Wraps `local.Client.Ping`; accepts either a tailnet IP *or* a MagicDNS hostname (resolved locally against `lc.Status()` before dialing). `type` maps to `tailcfg.PingType` (`disco` / `tsmp` / `icmp`). Result fields: `latency` (Duration, microsecond precision), `path` (a `PingPath` enum of `direct` / `derp` / `unknown` — ping types that don't expose endpoint metadata classify as `unknown` rather than falsely claiming relayed), `derpRegion` (three-letter code, populated only when `path == derp`). Convenience getters `.direct` and `.isRelayed` read off `path`.
- `diag.metrics()` → `Future<String>` is live. Returns the Prometheus-format scrape from `lc.UserMetrics` verbatim.
- `diag.derpMap()` → `Future<DERPMap>` is live. Wraps `lc.CurrentDERPMap`; marshals the upstream `tailcfg.DERPMap` with extended fields — `DERPRegion.{latitude,longitude,avoid,noMeasureNoHome}` and `DERPNode.{ipv4,ipv6,derpPort,stunPort,canPort80}` — so callers can build maps, diagnostics UI, or home-region pickers without dropping back to LocalAPI.
- `diag.checkUpdate()` → `Future<ClientVersion?>` is live. Returns `null` when already on the latest; otherwise a `ClientVersion` whose shape matches upstream `tailcfg.ClientVersion` (`latestVersion`, `urgentSecurityUpdate`, optional `notifyText`).

**Breaking — Phase 4 shape changes:**

- `ClientVersion` fields changed from `shortVersion` / `longVersion` to `latestVersion` / `urgentSecurityUpdate` / `notifyText?`. The previous fields had no direct upstream source and would have always been empty once this landed.
- `PingResult.direct` (bool) → `PingResult.path` (`PingPath` enum). The old bool collapsed "DERP-relayed" and "ping-type-didn't-report" into the same `false` value; the enum distinguishes them. A convenience `.direct` getter preserves the terse spelling for callers that only care about the positive case.

**Non-breaking — structured error codes:**

- Every Phase 4 LocalAPI wrapper now emits `{error, code?, statusCode?}` JSON envelopes; Dart side reads the code (`notFound` / `forbidden` / `conflict` / `preconditionFailed` / `featureDisabled`) and throws the per-namespace exception with the real `TailscaleErrorCode` instead of always `unknown`. Classification is HTTP-status-first (from `apitype.HTTPErr`) with a message-substring fallback for `featureDisabled`.

**Internal — Phase 4 refactors:**

- New `go/localapi.go` hosts all LocalAPI wrappers. Shared `lcOr(op)` helper factors the "running-check + LocalClient acquisition" pattern; `classifyLocalAPIError` + `localAPIError` centralize error-code emission.
- `Tls` and `Diag` namespaces refactored from const-singletons to abstract / `_impl` / factory shape (matching the existing `Tcp` pattern). Dependency-injected via `createTls` / `createDiag` from `Tailscale`; factories + typedefs hidden from the public `tailscale.dart` export.
- Worker isolate routing: new `tcpDial` / `tcpBind` / `tcpUnbind` / `whois` / `tlsDomains` / `diagPing` / `diagMetrics` / `diagDERPMap` / `diagCheckUpdate` operations, plus a new `_WorkerPeersEvent` pushed from the watcher isolate when `NotifyInitialNetMap` fires.

**Phase 3 — raw TCP between tailnet peers:**

- `tcp.dial(host, port, {timeout})` → `Future<Socket>` is live. Wraps `tsnet.Server.Dial` and bridges the tailnet connection through a per-call 127.0.0.1 loopback listener so the caller gets a standard `dart:io` `Socket`. A random 32-character hex token is written as the first bytes on the loopback conn to prevent co-resident processes from hijacking the bridge.
- `tcp.bind(port, {host})` → `Future<ServerSocket>` is live. Dart owns an ephemeral 127.0.0.1 `ServerSocket`; the Go side runs the tsnet listener and dials the loopback on each accepted tailnet connection. Closing the returned `ServerSocket` tears down the tailnet listener on the Go side too (via `DuneTcpUnbind`). No per-connection auth on this side — documented in the method's doc comment.
- New `TailscaleTcpException` for tailnet-side dial/listen failures and loopback bridge failures.
- E2E: two-node byte-echo test in `test/e2e/e2e_test.dart` — peer binds tailnet:7000 and echoes; main dials, sends a payload, verifies the round-trip.
- `example/tcp_echo.dart`: runnable demo (`dart run example/tcp_echo.dart server` / `client <ip>`).
- iOS + Android platform verification: not yet performed. Loopback binding works in the Dart VM on desktop; on iOS the tsnet runtime is known to run (PR #8 landed the `@rpath` install-name fix for that) but the loopback-bridge pattern hasn't been exercised there yet. Follow-up once this Phase 3 work ships.

**Breaking — namespaced API surface (Phase 1 of the API RFC; see `docs/api-roadmap.md`):**

- `Tailscale.http` (previously an `http.Client` getter) is now the `Http` namespace. Access the client via `Tailscale.http.client`.
- `Tailscale.listen(localPort, {tailnetPort})` (HTTP reverse-proxy helper) moved to `Tailscale.http.expose(localPort, {tailnetPort})` — same behavior, namespaced home.
- New namespaces declared on `Tailscale.instance`: `tcp`, `tls`, `udp`, `funnel`, `taildrop`, `serve`, `exitNode`, `profiles`, `prefs`, `diag`. All methods on these namespaces currently throw `UnimplementedError` — later RFC phases fill them in.
- New top-level members `Tailscale.whois(ip)` and `Tailscale.onPeersChange` declared but not yet implemented (Phase 2 / Phase 4).

Lifecycle (`up` / `down` / `logout` / `status` / `peers`), streams (`onStateChange` / `onError`), and the HTTP transport (`http.client` / `http.expose`) are fully wired through to existing behavior — no functional regression for callers that adopt the new names.

**Breaking — Phase 2 API hygiene:**

- `Tailscale.up()` now returns `Future<TailscaleStatus>` (previously `Future<void>`). Resolves on the first **stable** state (`running` / `needsLogin` / `needsMachineAuth`) rather than fire-and-forget, so interactive auth flows can branch on the returned `status.authUrl` without re-calling `up()`.
- `Tailscale.whois(ip)` → `Future<PeerIdentity?>` (nullable; null for unknown IPs instead of throwing).
- `profiles.current()` → `Future<LoginProfile?>` (nullable; fresh install has no current profile).
- `exitNode.use(PeerStatus)` is now type-safe. `useById(String stableNodeId)` is the escape hatch for persisted IDs. `useAuto()` added for `AutoExitNode` mode.
- `profiles.switchTo(LoginProfile)` + `switchToId(String)` / `delete(LoginProfile)` + `deleteById(String)` type-safe split (mirrors the `exitNode` pattern).
- `taildrop.get(name)` → `taildrop.openRead(name)` returning `Stream<Uint8List>`. `taildrop.push` data param is also `Stream<Uint8List>`.
- `prefs`: `MaskedPrefs` → `PrefsUpdate`; all setters prefixed `set*` (`setAdvertisedRoutes`, `setAdvertisedTags`, alongside `setAcceptRoutes` / `setShieldsUp` / `setAutoUpdate`). Fields on `TailscalePrefs` renamed to past tense (`advertisedRoutes`, `advertisedTags`) to pair with the setters.
- `TailscaleListenException` → `TailscaleHttpException` (thrown by any `http.*` call; `operation` field now `'http'` rather than the legacy `'listen'`).
- `FileTarget.hostname` → `FileTarget.hostName` (matches `PeerStatus.hostName` / `DERPNode.hostName` across the rest of the public surface).

**Non-breaking — Phase 2 additions:**

- Structured `TailscaleErrorCode` (`notFound` / `forbidden` / `conflict` / `preconditionFailed` / `featureDisabled` / `unknown`) and optional HTTP `statusCode` on every `TailscaleOperationException`.
- Per-namespace exception subtypes: `TailscaleTaildropException`, `TailscaleServeException`, `TailscalePrefsException`, `TailscaleProfilesException`, `TailscaleExitNodeException`, `TailscaleDiagException`.
- `PeerStatus.stableNodeId` — durable identifier that survives key rotation; preferred over `publicKey` for persisted peer references. Consumed by `exitNode.useById`.
- `FunnelMetadata` (`publicSrc`, `sni`) + `Socket.funnel` extension — Funnel edge attaches metadata to each accepted socket without subclassing `dart:io` types.
- `ServeConfig.etag` for optimistic concurrency on `serve.setConfig`; conflict is raised as `TailscaleServeException` with `TailscaleErrorCode.conflict`.
- Value-type equality (`==` / `hashCode` / `toString`) across 13 public value types — every value type except `PeerIdentity`, which is the one-shot return of `whois()` and isn't typically compared.
- Namespace constructors are `.internal()` and marked `@internal`, so consumers can't instantiate detached namespaces that aren't wired to the singleton engine.

## 0.2.0

- tsnet.Server.Close() doesn't fire a terminal state through the IPN bus, so onStateChange subscribers drifted from the engine — stuck at the pre-stop value (usually Running) and their UI routing went stale.
- Stop() now publishes Stopped, gated on srv != nil so a no-op stop stays silent. Logout() follows up with NoState after wiping creds (full sequence on logout from a running node: Stopped → NoState).
- Rewrites the onStateChange lifecycle e2e group around a new _recordUntil helper that captures full emitted sequences, and adds coverage for the no-op-down guard, broadcast delivery to multiple subscribers, and the ordered Stopped → NoState emit on logout.

## 0.1.0

- Initial release.
- Embed a Tailscale node directly in any Dart or Flutter application.
- `Tailscale.init()` — configure once at startup with state directory and log level.
- `up()` — start the embedded node and connect to a Tailscale or Headscale network.
- `http` — a standard `http.Client` that routes requests through the WireGuard tunnel.
- `listen()` — accept incoming traffic from the tailnet, forwarded to a local port.
- `status()` — typed `TailscaleStatus` with `NodeState` enum, local IPs, and health.
- `peers()` — typed `PeerStatus` snapshots, separate from status for lightweight polling.
- `onStateChange` / `onError` — real-time streams pushed from Go via NativePort (no polling).
- `down()` — disconnect, preserving state for reconnection.
- `logout()` — disconnect and clear persisted state.
- `NodeState` enum: `noState`, `needsLogin`, `needsMachineAuth`, `starting`, `running`, `stopped`.
- Automatic native Go compilation via Dart build hook — no manual build steps.
- Zero main-isolate jank: all FFI calls run on a background isolate.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Full test suite: unit, FFI integration, and E2E against Headscale in Docker.
