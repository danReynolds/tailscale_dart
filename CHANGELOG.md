## 0.4.0

A security and reliability release. It hardens the embedded-tsnet data plane,
tightens credential handling, and updates the bundled Tailscale stack. No
public API shape changes.

**Security:**

- Tailscale Funnel forwarding now strips reserved `Tailscale-*` identity headers
  (`Tailscale-User-Login`, etc.) from inbound public requests before proxying to
  the loopback backend, and pins `X-Forwarded-Proto`/`-Host`. Previously a public
  Funnel client could spoof these headers — which are only trustworthy on the
  authenticated Serve path — straight through to the backend.
- `logout()` now best-effort revokes the node key with the control plane before
  wiping local state (same on re-auth via `up()` with a new auth key). A
  surviving copy of the state database (e.g. a backup) is therefore no longer a
  live credential, and the device is deregistered rather than lingering until key
  expiry.
- The state database (node and machine private keys) is created owner-only
  (`0600`, including the WAL sidecars), and the state directory is enforced
  `0700` even when it already exists.
- The public Funnel listener now bounds concurrent connections to limit resource
  exhaustion from the open internet.

**Reliability and resource hygiene:**

- Established a single-owner rule for fd capabilities across the shared reactor
  and the main isolate, eliminating a deterministic cross-isolate double-close on
  registration failure (which under fd reuse could sever an unrelated live
  descriptor), plus a related response-fd over-close and an inbound-accept leak.
- Closing an HTTP binding now drains its accept backlog, releasing queued
  descriptors and unblocking their handler goroutines.
- Inbound UDP datagrams larger than 60 KiB are now dropped (and logged) instead
  of being silently truncated and delivered as a short datagram.
- The worker now fails API calls fast if its background isolate terminates,
  instead of hanging indefinitely.
- Additional fixes: TCP accept-loop descriptor leak and silent-failure handling,
  native-memory cleanup on decode errors, eager (fail-at-parse) string-list
  decoding, and closing the prior HTTP client on repeated `up()`.

**Dependencies and build:**

- Bumped `tailscale.com` from v1.92.2 to v1.96.5.
- **Now requires the Go 1.26.1 toolchain** (up from 1.25.5), enforced by the Go
  module directive. With the default `GOTOOLCHAIN=auto`, Go fetches it
  automatically — including on a Go 1.25 base — so no manual toolchain install is
  needed unless `GOTOOLCHAIN` is set to `local`/`off`.
- Added Dependabot (Go modules, pub, and GitHub Actions) and a least-privilege CI
  token.

**Documentation:**

- `init()` and the README now recommend storing state in a backup-excluded,
  app-private directory (the node's WireGuard key must not leak into iCloud or
  Google backups), and `WaitingFile.name` documents that the sender-chosen
  filename is attacker-controlled and must be sanitized before use in a path.

**Validation:**

- Verified against the existing unit, FFI, fd, runtime, Go, and Headscale E2E
  suites. The bundled-stack bump passes the full two-node Headscale E2E (node
  lifecycle, TCP/UDP/HTTP, persisted-credential reconnect, and logout revocation)
  identically to the prior version.

## 0.3.0

This release is a major API and transport rebuild for public POSIX usage.
It keeps the embedded-tsnet lifecycle model, but replaces the old loopback
transport helpers with package-native APIs backed by private fd capabilities
and a shared POSIX reactor.

**Platform contract:**

- `pubspec.yaml` declares Android, iOS, Linux, and macOS support. Windows is
  intentionally unsupported until a Windows-native data-plane backend or
  fallback carrier is designed.
- Linux CI runs Headscale E2E against the epoll reactor path; macOS, iOS, and
  Android have been validated through the demo/smoke harness.

**Breaking — public API shape:**

- `Tailscale.http` is now the HTTP namespace. Use `Tailscale.http.client` for a
  standard `package:http` client routed through the tailnet.
- The old `Tailscale.listen(localPort, {tailnetPort})` reverse-proxy helper was
  removed. Use `Tailscale.http.bind(port: ...)` for in-process HTTP handling, or
  `Tailscale.serve.forward(...)` when forwarding an existing loopback HTTP
  server.
- Inventory APIs now use Tailscale's node terminology:
  `Tailscale.nodes()`, `Tailscale.nodeByIp(ip)`, `Tailscale.onNodeChanges`,
  `TailscaleNode`, and `TailscaleNodeIdentity`.
- `Tailscale.up()` now returns `Future<TailscaleStatus>` and resolves on the
  first stable state (`running`, `needsLogin`, or `needsMachineAuth`).
- `PingResult.direct` is now `PingResult.path` (`PingPath.direct`, `derp`, or
  `unknown`). The `.direct` getter remains as a convenience for the positive
  case.
- `ClientVersion` now mirrors upstream fields: `latestVersion`,
  `urgentSecurityUpdate`, and optional `notifyText`.

**Core lifecycle and observation:**

- `TailscaleClient` is the testable app-facing interface implemented by
  `Tailscale.instance`.
- `onStateChange`, `onError`, and `onNodeChanges` are pushed from Go; node
  updates are debounced and new `onNodeChanges` subscribers receive the current
  snapshot.
- Structured `TailscaleErrorCode` and per-namespace operation exceptions now
  preserve known LocalAPI error categories (`notFound`, `forbidden`, `conflict`,
  `preconditionFailed`, `featureDisabled`, `unknown`).

**fd-backed transport APIs:**

- `http.client` streams outbound request/response bodies over private fd-backed
  channels while Go owns `tsnet.Server.HTTPClient()` semantics.
- `http.bind({port})` returns `TailscaleHttpServer` with package-native
  request/response objects and fd-backed request/response bodies.
- `tcp.dial(...)` and `tcp.bind(...)` provide package-native raw TCP streams and
  listeners via Go-owned `tsnet.Server.Dial/Listen` connections handed to Dart
  as private fd capabilities.
- `tls.bind(...)` accepts TLS-terminated tailnet connections as plaintext
  `TailscaleConnection`s; certificate acquisition and renewal remain in Go.
- `udp.bind(...)` provides message-preserving datagrams with remote endpoint
  metadata and rejects payloads over 60 KiB.
- The POSIX data plane uses a shared kqueue/epoll reactor instead of spawning
  reader/writer isolates per fd.

**Tailscale feature namespaces:**

- `whois(ip)` and `nodeByIp(ip)` are implemented for identity-aware
  authorization flows.
- `tls.domains()` exposes auto-provisioned Tailscale certificate SANs.
- `diag.ping`, `diag.metrics`, `diag.derpMap`, and `diag.checkUpdate` are
  implemented.
- `prefs.get`, single-field prefs setters, and `prefs.updateMasked` are
  implemented.
- `exitNode.current`, `suggest`, `use`, `useById`, `useAuto`, `clear`, and
  `onCurrentChange` are implemented.
- `serve.forward/clear` publishes an existing loopback HTTP service inside the
  tailnet using LocalAPI ServeConfig.
- `funnel.forward/clear` publishes an existing loopback HTTP service through
  Tailscale Funnel using `tsnet.ListenFunnel` plus a package-owned reverse
  proxy. Forwarding targets are loopback-only.
- `taildrop` and `profiles` remain declared roadmap namespaces and throw
  `UnimplementedError` in this release.

**Validation:**

- Unit, FFI, fd, runtime, Go, and Headscale E2E suites cover the core feature
  spine.
- Live Tailscale tests cover hosted-control-plane behavior Headscale cannot
  model: routing controls, TLS serving, Serve forwarding, Funnel forwarding,
  and Serve cleanup on `down()`/restart.

**Release hardening:**

- HTTP fd response-head envelopes are capped at 256 KiB on both the Dart and
  Go sides.
- fd transport write/close dispatch failures, listener/server close failures,
  unread HTTP request bodies, and UDP binding teardown paths now deterministically
  close local resources.
- Serve/Funnel forwarding canonicalizes `localhost` to `127.0.0.1` before
  creating loopback proxy targets.
- Smoke-matrix tooling redacts bearer credentials from logs and stores generated
  runner tokens with owner-only file permissions.

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
