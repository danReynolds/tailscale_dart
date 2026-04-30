## Unreleased

**Platform contract:**

- `pubspec.yaml` now declares the supported v1 platforms: Android, iOS, Linux,
  and macOS. Windows remains intentionally unsupported until a Windows-native
  data-plane backend or fallback carrier is designed.
- `Tailscale.onNodeChanges` has regression coverage for replaying the current
  node snapshot to new subscribers before future inventory changes.

**Breaking — node terminology:**

- Public inventory APIs now use Tailscale's node terminology: `Tailscale.nodes()`, `Tailscale.nodeByIp(ip)`, `Tailscale.onNodeChanges`, `TailscaleNode`, and `TailscaleNodeIdentity`.

**Breaking — HTTP transport cleanup:**

- `Tailscale.http.bind(port: ...)` now returns a `TailscaleHttpServer` with a single-subscription `requests` stream. Inbound HTTP no longer reverse-forwards to a caller-owned local port; request bodies and response bodies stream through private fd-backed channels.
- `Tailscale.http.client` no longer uses a local loopback proxy. Outbound request and response bodies stream through private fd-backed channels while Go's `tsnet.Server.HTTPClient()` owns the tailnet HTTP semantics.

**Phase 5 — UDP datagrams:**

- `udp.bind({port, address})` → `Future<TailscaleDatagramBinding>` is live on POSIX. Wraps `tsnet.Server.ListenPacket`; Go owns the tailnet packet listener and hands Dart a private datagram socketpair-backed fd capability.
- New package-native UDP types: `TailscaleDatagramBinding` and `TailscaleDatagram`. Datagrams preserve message boundaries and attach the remote `TailscaleEndpoint` to each delivery.
- `TailscaleDatagramBinding.send(payload, to: endpoint)` rejects payloads over 60 KiB rather than fragmenting.
- New `TailscaleUdpException` for tailnet-side bind failures, invalid endpoints, oversize datagrams, and fd handoff failures.
- E2E: two-node UDP echo test in `test/e2e/e2e_test.dart` — the second node binds tailnet:7001 and echoes datagrams; main binds an ephemeral UDP endpoint, sends a payload, verifies the round-trip.

**Phase 4 — LocalAPI one-shots:**

- `Tailscale.whois(ip)` → `Future<TailscaleNodeIdentity?>` is live. Wraps `local.Client.WhoIs`; 404 from LocalAPI (unknown IP on this tailnet) maps to `null`, other errors throw.
- `Tailscale.onNodeChanges` → `Stream<List<TailscaleNode>>` is live. The Go-side IPN bus watcher now subscribes to `NotifyInitialNetMap` in addition to `NotifyInitialState`. A NetMap burst is debounced with a 100ms trailing-edge timer before fetching `lc.Status()` and serializing the node list, so endpoint reshuffles and relay flaps don't produce one publish per tick. Dedup is left to subscribers — pipe through `.distinct()` if you only want real transitions.
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

**Phase 3 — raw TCP between tailnet nodes:**

- `tcp.dial(host, port, {timeout})` → `Future<TailscaleConnection>` is live on POSIX. Wraps `tsnet.Server.Dial`; Go owns the tailnet connection and hands Dart a private socketpair-backed fd capability.
- `tcp.bind({port, address})` → `Future<TailscaleListener>` is live on POSIX. Go owns the `tsnet.Server.Listen("tcp", ...)` listener; Dart receives each accepted tailnet connection as a `TailscaleConnection`.
- New package-native TCP types: `TailscaleEndpoint`, `TailscaleConnection`, `TailscaleConnectionOutput`, and `TailscaleListener`. These are not compatibility wrappers around `dart:io` sockets.
- New `TailscaleTcpException` for tailnet-side dial/listen failures and fd handoff failures.
- E2E: two-node byte-echo test in `test/e2e/e2e_test.dart` — the second node binds tailnet:7000 and echoes; main dials, sends a payload, verifies the round-trip.
- `example/tcp_echo.dart`: runnable demo (`dart run example/tcp_echo.dart server` / `client <ip>`).
- iOS + Android platform verification: manual demo probes now pass for HTTP, TCP, and UDP on both platforms.

**Breaking — namespaced API surface (Phase 1 of the API RFC; see `docs/api-roadmap.md`):**

- `Tailscale.http` (previously an `http.Client` getter) is now the `Http` namespace. Access the client via `Tailscale.http.client`.
- `Tailscale.listen(localPort, {tailnetPort})` (HTTP reverse-proxy helper) was removed. The current API is `Tailscale.http.bind(port: ...)`, which yields package-native HTTP request/response objects.
- New namespaces declared on `Tailscale.instance`: `tcp`, `tls`, `udp`, `funnel`, `taildrop`, `serve`, `exitNode`, `profiles`, `prefs`, `diag`. `tcp`, `udp`, `diag`, and `tls.domains()` are implemented in this release; TLS listener, Funnel, Taildrop, Serve, ExitNode, Profiles, and Prefs remain roadmap items.
- New top-level members `Tailscale.whois(ip)` and `Tailscale.onNodeChanges` are implemented.

Lifecycle (`up` / `down` / `logout` / `status` / `nodes`), streams (`onStateChange` / `onError`), and the HTTP transport (`http.client` / `http.bind`) are fully wired through to existing behavior.

**Breaking — Phase 2 API hygiene:**

- `Tailscale.up()` now returns `Future<TailscaleStatus>` (previously `Future<void>`). Resolves on the first **stable** state (`running` / `needsLogin` / `needsMachineAuth`) rather than fire-and-forget, so interactive auth flows can branch on the returned `status.authUrl` without re-calling `up()`.
- `Tailscale.whois(ip)` → `Future<TailscaleNodeIdentity?>` (nullable; null for unknown IPs instead of throwing).
- `profiles.current()` → `Future<LoginProfile?>` (nullable; fresh install has no current profile).
- `exitNode.use(TailscaleNode)` is now type-safe. `useById(String stableNodeId)` is the escape hatch for persisted IDs. `useAuto()` added for `AutoExitNode` mode.
- `profiles.switchTo(LoginProfile)` + `switchToId(String)` / `delete(LoginProfile)` + `deleteById(String)` type-safe split (mirrors the `exitNode` pattern).
- `taildrop.get(name)` → `taildrop.openRead(name)` returning `Stream<Uint8List>`. `taildrop.push` data param is also `Stream<Uint8List>`.
- `prefs`: `MaskedPrefs` → `PrefsUpdate`; all setters prefixed `set*` (`setAdvertisedRoutes`, `setAdvertisedTags`, alongside `setAcceptRoutes` / `setShieldsUp` / `setAutoUpdate`). Fields on `TailscalePrefs` renamed to past tense (`advertisedRoutes`, `advertisedTags`) to pair with the setters.
- `TailscaleListenException` → `TailscaleHttpException` (thrown by any `http.*` call; `operation` field now `'http'` rather than the legacy `'listen'`).
- `FileTarget.hostname` → `FileTarget.hostName` (matches `TailscaleNode.hostName` / `DERPNode.hostName` across the rest of the public surface).

**Non-breaking — Phase 2 additions:**

- Structured `TailscaleErrorCode` (`notFound` / `forbidden` / `conflict` / `preconditionFailed` / `featureDisabled` / `unknown`) and optional HTTP `statusCode` on every `TailscaleOperationException`.
- Per-namespace exception subtypes: `TailscaleTaildropException`, `TailscaleServeException`, `TailscalePrefsException`, `TailscaleProfilesException`, `TailscaleExitNodeException`, `TailscaleDiagException`.
- `TailscaleNode.stableNodeId` — durable identifier that survives key rotation; preferred over `publicKey` for persisted node references. Consumed by `exitNode.useById`.
- `FunnelMetadata` (`publicSrc`, `sni`) + `Socket.funnel` extension — Funnel edge attaches metadata to each accepted socket without subclassing `dart:io` types.
- `ServeConfig.etag` for optimistic concurrency on `serve.setConfig`; conflict is raised as `TailscaleServeException` with `TailscaleErrorCode.conflict`.
- Value-type equality (`==` / `hashCode` / `toString`) across public value types, including `TailscaleNode` and `TailscaleNodeIdentity`.
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
- `nodes()` — typed `TailscaleNode` snapshots, separate from status for lightweight polling.
- `onStateChange` / `onError` — real-time streams pushed from Go via NativePort (no polling).
- `down()` — disconnect, preserving state for reconnection.
- `logout()` — disconnect and clear persisted state.
- `NodeState` enum: `noState`, `needsLogin`, `needsMachineAuth`, `starting`, `running`, `stopped`.
- Automatic native Go compilation via Dart build hook — no manual build steps.
- Zero main-isolate jank: all FFI calls run on a background isolate.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Full test suite: unit, FFI integration, and E2E against Headscale in Docker.
