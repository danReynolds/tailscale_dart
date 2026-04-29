# Runtime Transport Journal

This journal records implementation notes for the fd-backed runtime transport
direction. It is intentionally practical: what changed, what was learned, what
still needs a decision.

## 2026-04-29: Shared reactor review tightening

### Changes

- Fixed the Linux epoll backend so readiness events carry the fd and resolve to
  the full 64-bit transport id through an internal `fd -> id` map. This avoids
  truncating ids through `EpollEvent.Fd` and removes the wake-event sentinel
  collision.
- Made `eventfd` wake writes explicit little-endian `uint64(1)`.
- Moved inbound queue accounting into the reactor isolate. Read interest is now
  disabled when a transport has `maxInboundQueuedBytes` outstanding and
  re-enabled only after Dart acknowledges delivered input bytes.
- Changed the read path from one read per readiness event to bounded draining
  up to `_reactorReadBudgetBytes`, while still yielding after a fixed budget.
- Reused per-transport write scratch buffers instead of allocating native
  memory for every write chunk.
- Added the internal sharding hook (`forTransport(fd)`) with shard count fixed
  at one. This keeps today's behavior but preserves the ownership boundary for
  future stress-driven sharding.
- Added an inbound queue-bound regression test.

### Decision

- Kept the short idle-grace reactor shutdown. A permanent process-wide reactor
  isolate would make CLI/tests/benchmarks harder to terminate cleanly without a
  new explicit runtime shutdown path. Registration retry still handles the
  narrow idle-exit race, and this can be revisited if `Tailscale.dispose()`
  becomes the single owner of reactor lifetime.

### Validation

- `dart analyze`
- `go test ./...` in `go/`
- `dart test --enable-experiment=native-assets test/integration/fd/posix_fd_transport_test.dart -r expanded`
- `dart test --enable-experiment=native-assets`
- `dart --enable-experiment=native-assets benchmark/fd_transport.dart --json`

## 2026-04-23: POSIX fd foundation

### Context

We reset away from the universal authenticated loopback session protocol and
started the capability-first backend direction:

- POSIX data plane uses fd handoff via socketpair-backed capabilities.
- Addressable carriers such as loopback TCP remain fallback/backend-specific,
  not the default architecture.
- Public TCP/UDP/HTTP API semantics stay separate from backend mechanics.

### Changes

- Added `PosixFdTransport`, an internal Dart primitive that adopts a POSIX fd,
  reads and writes from background isolates, supports ordered writes,
  write-half shutdown, full close, bounded pending writes, and
  single-subscription input.
- Added socketpair-based Dart tests for bidirectional bytes, copy-before-async
  write ownership, queued write ordering, half-close behavior, full close,
  pending-write bounds, and single-subscription input.
- Added Go `TcpDialFd` on POSIX: tsnet dials the peer, Go creates a socketpair,
  pipes one end to the tailnet connection, and returns the other fd to Dart.
- Added a Windows stub that fails explicitly instead of pretending the POSIX fd
  backend exists there.
- Exported `DuneTcpDialFd` and added a Dart FFI binding plus validation test.

### Emergent Finding

`StreamController.close()` must not be awaited during transport teardown when
the stream may never have had a listener. For single-subscription streams, the
close future can wait for done delivery, which means cleanup can hang if the
application never consumed `input`.

The fd transport now signals input closure without making descriptor cleanup
depend on listener behavior. This should carry into public connection/listener
lifecycle code.

### Validation

- `dart analyze`
- `dart test`
- `go test ./...` in `go/`

### Next

- Add a small public/internal connection adapter over `PosixFdTransport` so the
  fd backend can support the transport API without exposing fd mechanics.
- Add Headscale E2E coverage for `DuneTcpDialFd` once the adapter can exercise
  a real tailnet connection from Dart.
- Design inbound TCP fd accept separately; do not reuse the old loopback bind
  semantics unless POSIX accept handoff proves insufficient.

## 2026-04-23: Runtime connection adapter and real-tailnet fd TCP

### Changes

- Added `RuntimeConnection`, the internal byte-stream semantic layer above
  backend-specific transports.
- Added worker plumbing for `tcpDialFd`, so the Dart worker isolate can request
  a native POSIX TCP fd without going through the old loopback bridge.
- Added Headscale E2E coverage that dials the peer echo server via
  `DuneTcpDialFd`, wraps the returned fd in `RuntimeConnection`, writes bytes,
  gracefully half-closes output, and reads the echoed bytes back.

### Emergent Findings

- `tsnet.Server.Listen("tcp", ...)` does not always expose a concrete
  `*net.TCPAddr` through `Listener.Addr()`. The old `TcpBind` bridge rejected
  the listener as unresolved even though the address string contained the port.
  The port extraction now falls back to `net.SplitHostPort(addr.String())`.
- Headscale's LocalAPI can report unknown `WhoIs` targets as `peer not found`
  without a typed 404 wrapper. The not-found classifier now treats that as the
  expected `found: false` case so Dart returns `null` as documented.

### Validation

- `dart analyze`
- `dart test`
- `go test ./...` in `go/`
- `test/e2e/run_e2e.sh`

The E2E run passed all 30 tests. The fd-backed TCP test passed against the
real Headscale-controlled tailnet.

### Next

- Move the public raw TCP surface to package-native connection/listener types
  with no compatibility bridge.
- Implement inbound POSIX TCP fd accept using a listener id plus a blocking
  accept isolate.

## 2026-04-23: Public TCP API moved to package-native fd-backed types

### Changes

- Added `TailscaleEndpoint`, `TailscaleConnection`,
  `TailscaleConnectionOutput`, and `TailscaleListener` as the public raw TCP
  surface.
- Changed `tcp.dial` to return `Future<TailscaleConnection>` and `tcp.bind` to
  return `Future<TailscaleListener>`.
- Implemented inbound POSIX TCP accept with `DuneTcpListenFd`,
  `DuneTcpAcceptFd`, and `DuneTcpCloseFdListener`. Dart starts a dedicated
  accept isolate when `listener.connections` is first listened to.
- Removed the old token-authenticated loopback TCP bridge from the public path
  and native exports. TCP now goes through fd-backed capabilities on POSIX.
- Updated the TCP example, Headscale E2E peer, API docs, and changelog to the
  package-native surface.

### Emergent Findings

- Inbound accept does not need SCM_RIGHTS or a readiness fd for v1. A blocking
  accept isolate is smaller and maps cleanly onto `DuneTcpAcceptFd`.
- The no-compatibility-bridge decision is important for API clarity. Leaving
  unused loopback bridge exports around makes the implementation look like it
  still supports socket-shaped semantics, so those paths were removed.

### Validation

- `dart analyze`
- `dart test`
- `go test ./...` in `go/`
- `test/e2e/run_e2e.sh`

The E2E run passed all 29 tests after the public API switch.

### Next

- Implement the package-native UDP datagram API and backend.
- Decide whether the remaining TLS/Funnel stubs should be reshaped before
  their implementations land.

## 2026-04-23: Public UDP API moved to package-native fd-backed datagrams

### Changes

- Added `TailscaleDatagram` and `TailscaleDatagramBinding` as the public UDP
  surface.
- Changed `udp.bind({port, address})` from an unimplemented `RawDatagramSocket`
  stub to `Future<TailscaleDatagramBinding>`.
- Implemented POSIX UDP with `DuneUdpBindFd`. Go opens
  `tsnet.Server.ListenPacket`, creates an `AF_UNIX/SOCK_DGRAM` socketpair, and
  bridges datagrams with a small endpoint envelope.
- Added Dart tests for datagram value semantics, message-preserving fd-backed
  delivery, oversize rejection, single-subscription receive streams, and
  before-`up()` failure.
- Added Headscale E2E coverage for a two-node UDP echo round trip.

### Emergent Findings

- `tsnet.Server.ListenPacket` requires a concrete local tailnet IP. The public
  API keeps that explicit: callers bind with `status().ipv4` or another local
  tailnet address, not `0.0.0.0`.
- Datagram receive is intentionally not backpressured. The Dart binding drops
  datagrams while no listener is attached or while the subscription is paused,
  rather than pretending UDP has stream-like delivery guarantees.
- A single datagram socketpair is enough for POSIX. We do not need a listener
  registry or accept loop for UDP because one packet listener maps to one
  long-lived datagram fd capability.

### Validation

- `dart analyze`
- `dart test test/udp_test.dart`
- `go test ./...` in `go/`
- `test/e2e/run_e2e.sh`

The E2E run passed all 30 tests after adding UDP.

### Next

- Run the full `dart test` suite after the docs settle.
- Decide whether `tls.bind` and Funnel should stay socket-shaped stubs or move
  to package-native surfaces before implementation.

## 2026-04-23: Demo validation packages scaffolded

### Changes

- Added `packages/demo_core`, a plain Dart package that owns reusable
  validation behavior: node startup, peer listing, HTTP/TCP/UDP echo services,
  and peer probes.
- Added `packages/demo_flutter`, a Flutter app for macOS, iOS, and Android
  manual validation against another tailnet peer.
- Kept the app UI thin. All Tailscale behavior lives in `demo_core` so the
  same harness can later back a CLI or daemon-style validation runner.
- Added basic platform networking permissions for the Flutter demo:
  macOS client/server network entitlements, Android `INTERNET`, and an iOS
  local-network usage string.

### Emergent Findings

- Nested package shell resolution currently finds `/usr/local/bin/dart`
  before the project Flutter SDK, which is an older Dart 3.6 install. Validation
  for `demo_core` should use `/Users/dan/Coding/flutter_arm64/bin/dart` until
  the local PATH ordering is cleaned up.
- `demo_core` depends on the root package's native-assets hook. Its tests pass
  with `dart test --enable-experiment=native-assets`; plain `dart test` reports
  that native assets must be enabled.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`

## 2026-04-29: Shared reactor benchmark harness

### Changes

- Added `benchmark/fd_transport.dart`, a local POSIX fd data-plane benchmark
  that can run against both the pre-reactor backend and the shared-reactor
  backend without using reactor-only debug hooks.
- Added `benchmark/README.md` with before/after commands and interpretation
  guidance for one-way throughput, small-write latency, churn, full-duplex
  throughput, fairness under load, HTTP-shaped request/response loops, and RSS
  deltas.
- Fixed a stale-reactor adoption race surfaced by the benchmark: after the last
  fd closed, the reactor isolate could exit before the main isolate observed
  the exit, leaving a dead proxy for the next immediate adoption. Adoption now
  retries once and stores only the reactor proxy that actually registered the
  fd.
- Changed reactor idle shutdown from immediate exit to a short grace period.
  This preserves cleanup while avoiding avoidable stale-proxy retries during
  normal connection churn.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
- `/Users/dan/Coding/flutter_arm64/bin/dart run --enable-experiment=native-assets benchmark/fd_transport.dart --pairs=1,10 --extra-pairs=1,10 --payload-mib=1 --latency-writes=20 --churn-count=20 --http-requests=20 --json`
- `/Users/dan/Coding/flutter_arm64/bin/dart run --enable-experiment=native-assets benchmark/fd_transport.dart --json`
- Copied the benchmark into a detached `main` worktree and confirmed the
  before/after-compatible smoke command runs there:
  `/Users/dan/Coding/flutter_arm64/bin/dart run --enable-experiment=native-assets benchmark/fd_transport.dart --pairs=1,10 --extra-pairs=1 --payload-mib=1 --latency-writes=20 --churn-count=20 --http-requests=20 --json`

## 2026-04-29: Shared POSIX fd reactor

### Changes

- Replaced the two-isolates-per-fd transport backend with a shared POSIX fd
  reactor isolate.
- Added native poller shims inside the existing Go native asset:
  `kqueue`/`EVFILT_USER` on Darwin and `epoll`/`eventfd` on Linux/Android.
- Kept `PosixFdTransport` as the internal facade used by TCP, UDP, and HTTP so
  public package-native APIs do not change.
- Preserved ordered writes, copy-before-async-write ownership, pause-aware
  input, half-close, full close, and deterministic fd cleanup.
- Added a private reactor diagnostic snapshot for tests and future debugging.
- Tightened the shared reactor RFC around sharding, accept-loop ownership,
  fairness, queue bounds, validation order, and observability.

### Validation

- `go test ./...` in `go`
- `/Users/dan/Coding/flutter_arm64/bin/dart analyze`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets test/integration/fd`

## 2026-04-24: Transport reliability hardening after mobile validation

### Context

macOS, iOS, and Android manual probes now pass across ping, whois, HTTP, TCP,
and UDP. With the cross-platform shape validated, the next priority became
correctness and lifecycle hardening rather than API expansion.

### Changes

- Closed all registered POSIX TCP fd listeners from `Stop()`/runtime teardown
  so `tcp.bind()` listeners cannot survive a node restart.
- Before the later fd-backed HTTP collapse, changed the reverse HTTP proxy to
  stream incoming request bodies directly to the local Dart server instead of
  buffering the full body in Go.
- Before the later fd-backed HTTP collapse, kept reverse-proxy requests
  fail-fast when no local target port is configured.
- Tightened Dart UDP envelope validation to match the Go side for empty
  addresses, invalid ports, malformed UTF-8, and malformed inbound envelopes.
- Propagated UDP transport input errors through the binding's `done` future
  instead of silently completing successfully.

### Validation

- `go test ./...` in `go/`
- `dart test test/fd_transport_test.dart test/runtime_connection_test.dart test/udp_test.dart test/proxy_client_test.dart test/lifecycle_test.dart test/tcp_test.dart`
- `dart analyze`
- `git diff --check`

## 2026-04-24: PR-readiness cleanup

### Changes

- Updated the roadmap and API status docs so completed Phase 1/2/3/4 items,
  mobile fd validation, and UDP transport status match the implementation.
- Added `docs/pr-readiness.md` to frame the PR as a capability-first POSIX
  backend replacement, with old session transport work explicitly out of scope.
- Cleaned generated demo-package artifacts from the working tree and added
  ignore coverage for local editor state.
- Excluded nested demo packages from root `dart analyze`; each demo package is
  analyzed in its own package context.
- Consolidated duplicated POSIX fd socketpair test helpers into
  `test/support/posix_fd_test_support.dart`.
- Added a Go regression test proving the reverse HTTP proxy streams request
  bodies to the local target before request-body EOF.

### Validation

- `go test -count=1 ./...` in `go/`
- `dart test`
- `dart analyze`

## 2026-04-25: HTTP lane collapsed onto fd-backed transport

### Context

The HTTP API still had the shape of the earlier local-proxy implementation:
outbound requests were rewritten through a loopback HTTP proxy and inbound
publishing used `http.expose`. TCP and UDP had already moved to kernel
fd-backed capabilities, so HTTP was the remaining parallel data path.

### Changes

- Replaced the outbound local proxy with `TailscaleHttpClient`, which keeps the
  public `package:http.Client` interface while streaming request and response
  bodies over private fd-backed channels to Go's `tsnet.Server.HTTPClient()`.
- Replaced `http.expose(localPort, {tailnetPort})` with
  `http.bind(port: ...)`, returning a closable
  `TailscaleHttpServer` with a package-native request stream and tailnet
  endpoint metadata.
- Removed proxy auth-token plumbing, proxy request rewriting, and the
  Dart-side proxy client.
- Moved inbound HTTP off local reverse forwarding. Requests and responses now
  cross the Dart/Go boundary through private fd-backed body streams, matching
  the TCP/UDP v1 backend direction.
- Updated README, roadmap/status docs, examples, demo core, benchmark, and FFI
  tests for the new API.

### Validation

- `go test -count=1 ./...` in `go/`
- `dart analyze`
- `dart test`
- `/Users/dan/Coding/flutter_arm64/bin/dart test` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/flutter test` in `packages/demo_flutter`
- `/Users/dan/Coding/flutter_arm64/bin/flutter analyze` in `packages/demo_flutter`
- `DART=/Users/dan/Coding/flutter_arm64/bin/dart test/e2e/run_e2e.sh`
- `git diff --check`

## 2026-04-23: Headless + macOS demo validation

### Findings

- A first headless `demo_node serve` run was started without a TTY. Because
  `serve` treats stdin close as a stop signal, the node went offline while the
  Dart process stayed around during shutdown. Headscale correctly reported the
  peer as offline, and macOS probe attempts could only see a stale peer record.
- Relaunching `demo_node serve` with a TTY kept the headless node online. The
  macOS Flutter demo then joined the same local Headscale and passed ping,
  whois, HTTP GET/POST, TCP echo, and UDP echo against the headless peer.
- The reverse probe initially reproduced the mobile-style failure: ping/whois
  passed, but HTTP/TCP/UDP to the Flutter app failed. Root cause was stale demo
  service state after a node restart/rejoin. The Flutter UI still believed
  services from the prior tsnet generation were running, so it skipped rebinding
  HTTP/TCP/UDP for the current node IP.

### Changes

- Added `DUNE_DEMO_HOSTNAME`, `DUNE_DEMO_AUTH_KEY`,
  `DUNE_DEMO_CONTROL_URL`, and `DUNE_DEMO_NODE_IP` dart-define defaults for
  faster macOS demo iteration without brittle text-field automation.
- Made `DemoCore.up()` stop existing demo services before starting/rejoining a
  node.
- Made `DemoCore.startServices()` verify that cached services match the current
  node IPv4 address and rebind services when the runtime generation changed.
- Removed the Flutter UI's stale `_services != null` shortcut before starting
  services, and cleared displayed services before admin/client joins.

### Validation

- Local Headscale with one TTY-backed `demo_node serve` node and one macOS
  Flutter demo node.
- macOS -> headless probe: PASS for ping, whois, HTTP GET, HTTP POST, TCP echo,
  and UDP echo.
- Headless -> macOS probe: PASS for ping, whois, HTTP GET, HTTP POST, TCP echo,
  and UDP echo.
- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/flutter analyze` in
  `packages/demo_flutter`
- `/Users/dan/Coding/flutter_arm64/bin/flutter test` in `packages/demo_flutter`
- `git diff --check`

## 2026-04-24: Demo validation hardening

### Changes

- Changed `demo_node serve` so stdin EOF no longer stops the node by default.
  It now stays alive until `SIGINT`/`SIGTERM`. Automation that needs stdin
  commands must opt in with `--stdin-control`.
- Updated `demo_node pair` to pass `--stdin-control` to its managed child
  nodes, preserving the existing `PROBE <ip>` and `STOP` protocol.
- Added a `DemoCore.startServices()` regression test that verifies services are
  reused for the same node IP but stopped and rebound when the node IPv4
  changes.
- Documented the Flutter demo local Headscale flow, including Client vs Admin
  mode, auth-key generation, and `localhost` vs physical-device LAN control
  URLs.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/flutter analyze` in
  `packages/demo_flutter`
- `/Users/dan/Coding/flutter_arm64/bin/flutter test` in `packages/demo_flutter`
- `/Users/dan/Coding/flutter_arm64/bin/dart run --enable-experiment=native-assets bin/demo_node.dart --help`
  in `packages/demo_core`
- `git diff --check`

## 2026-04-24: Self stable node ID on status

### Changes

- Added `TailscaleStatus.stableNodeId`, parsed from LocalAPI `Self.ID`, so
  callers can get this node's stable Tailscale identity without doing a
  self-`whois` workaround.
- Included the self stable ID in `TailscaleStatus` equality, hashCode, and
  `toString`.
- Added the stable ID to the Flutter demo Runtime Telemetry panel for manual
  device validation.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze`
- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/flutter analyze` in
  `packages/demo_flutter`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets test/lifecycle_test.dart`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/flutter test` in `packages/demo_flutter`
- `git diff --check`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/dart run --enable-experiment=native-assets bin/demo_node.dart --help`
  in `packages/demo_core`
- Local Headscale run with `demo_node pair`: two macOS headless nodes passed
  ping, whois, HTTP GET/POST, TCP echo, and UDP echo in both directions.
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `flutter analyze` in `packages/demo_flutter`
- `flutter test` in `packages/demo_flutter`
- `flutter build macos --debug` in `packages/demo_flutter`
- `flutter build apk --debug` in `packages/demo_flutter`
- `flutter build ios --simulator --debug` in `packages/demo_flutter`

### Next

- Run the demo app locally on macOS against the Headscale E2E peer.
- Add iOS and Android manual validation notes once the app has been installed
  on real devices or simulators.

## 2026-04-23: Demo app admin key generation and cyber UI pass

### Changes

- Reused the Dune admin auth-key shape in `demo_core`: Basic auth to
  `POST /api/v2/tailnet/{tailnet}/keys`, one-day expiry by default, and
  configurable reusable, ephemeral, and preauthorized flags.
- Added Admin and Client modes to the Flutter demo. Admin mode can join with
  a Tailscale API key and tailnet ID, while Client mode joins with a client
  auth key.
- Reworked the Flutter demo visual language into a dark terminal console with
  neon green/cyan accents, scanline/grid background, cyber panels, status
  chips, and a dedicated Client Invite section.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `flutter analyze` in `packages/demo_flutter`
- `flutter test` in `packages/demo_flutter`
- `flutter build macos --debug` in `packages/demo_flutter`
- `flutter build ios --simulator --debug` in `packages/demo_flutter`

## 2026-04-23: Demo app role-specific admin/client UX

### Changes

- Made Client and Admin join flows mutually exclusive in the Flutter demo.
  Client mode shows only auth-key/control-URL joining; Admin mode shows only
  Tailscale API key and tailnet ID for joining.
- Added `DemoCore.upAsAdmin`, which generates the admin node auth key
  internally and then joins the tailnet without displaying that key.
- Moved client auth-key issuing into an Admin-only Client Invite panel. The
  issued key is for another device, not for the admin node's local join flow.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
- `/Users/dan/Coding/flutter_arm64/bin/dart test --enable-experiment=native-assets`
  in `packages/demo_core`
- `flutter analyze` in `packages/demo_flutter`
- `flutter test` in `packages/demo_flutter`
- `flutter build macos --debug` in `packages/demo_flutter`
- `flutter build apk --debug` in `packages/demo_flutter`
- `flutter build ios --simulator --debug` in `packages/demo_flutter`
- `dart analyze`
- `dart test`

## 2026-04-23: Demo Flutter platform identifiers renamed

### Changes

- Renamed the Flutter demo package/app from `demo_flutter` to
  `dune_core_flutter`.
- Replaced the default `com.example.demoFlutter` iOS/macOS bundle identifiers
  with `com.dune.dunecoreflutter`.
- Aligned the Android namespace/application ID and Kotlin activity package to
  `com.dune.dunecoreflutter`.

### Validation

- `flutter analyze` in `packages/demo_flutter`
- `flutter test` in `packages/demo_flutter`
- `flutter build ios --simulator --debug` in `packages/demo_flutter`
- `flutter build ios --debug --no-codesign` in `packages/demo_flutter`
- `flutter build macos --debug` in `packages/demo_flutter`
- `flutter build apk --debug` in `packages/demo_flutter`

## 2026-04-23: Demo peer filtering and service-start recovery

### Changes

- Added an Online-only filter to the Flutter demo Node Matrix so manual
  device validation can hide stale/offline peers without losing the raw peer
  snapshot.
- Added an explicit Start services action and an automatic service-start retry
  when the node transitions to `running`. This covers the mobile startup path
  where `up()` may return while the node is still settling through
  `starting -> running`.
- Added an active-operation indicator to the header so slow iOS joins show
  visible progress while tsnet handles control-plane login and netcheck.

### Validation

- `flutter analyze` in `packages/demo_flutter`
- `flutter test` in `packages/demo_flutter`
- `flutter build macos --debug` in `packages/demo_flutter`
- `flutter build ios --debug --no-codesign` in `packages/demo_flutter`

## 2026-04-23: Headless demo node for faster local iteration

### Changes

- Added `packages/demo_core/bin/demo_node.dart`, a CLI wrapper around
  `DemoCore` for running the same serve/probe logic without Flutter deploys.
- Added `serve`, `probe`, and `pair` modes. `pair` spawns two separate Dart
  processes so each process owns exactly one embedded tsnet runtime.
- Kept stdout machine-readable with `READY` and `PROBE_RESULT` lines so the
  CLI can be used by scripts and future E2E harnesses.

### Validation

- `/Users/dan/Coding/flutter_arm64/bin/dart analyze` in `packages/demo_core`
