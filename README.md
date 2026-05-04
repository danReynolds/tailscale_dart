<p align="center">
  <img width="160" height="160" alt="tailscale.dart logo" src="https://github.com/user-attachments/assets/56a2a857-c5e7-42eb-9366-506daa56c5f9" />
</p>

# Dart 💙 Tailscale

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/danReynolds/tailscale_dart/blob/main/LICENSE)
[![Dart 3.10+](https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux-brightgreen.svg)](#platform-support)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-70ffb1.svg)](https://danreynolds.github.io/tailscale_dart/)
[![API reference](https://img.shields.io/badge/api-dartdoc-0175C2.svg)](https://danreynolds.github.io/tailscale_dart/api/)

Embed a real [Tailscale](https://tailscale.com) or [Headscale](https://github.com/juanfont/headscale) node inside a Dart or Flutter app.

`package:tailscale` uses upstream Go [`tsnet`](https://pkg.go.dev/tailscale.com/tsnet) under the hood, then exposes typed Dart APIs for lifecycle, node identity, HTTP, TCP, UDP, TLS, Serve, Funnel, prefs, exit nodes, and diagnostics. The app authenticates as its own tailnet node and can communicate over encrypted WireGuard tunnels without requiring users to install or control a system-wide VPN app.

## Documentation

The [**developer site**](https://danreynolds.github.io/tailscale_dart/) is the canonical place to browse the package — full guide, examples, architecture diagrams, and a runtime model walkthrough.

| Where | What |
| --- | --- |
| [Developer site](https://danreynolds.github.io/tailscale_dart/) | Guide, examples, architecture — start here for rich browsing |
| [API reference](https://danreynolds.github.io/tailscale_dart/api/) | Generated dartdoc for every public symbol |
| [pub.dev](https://pub.dev/packages/tailscale) | Install, versions, changelog |
| [`example/`](example/) | Runnable Dart snippets |
| [`doc/`](doc/) | API status, roadmap, RFCs, and architecture notes |
| [`test/README.md`](test/README.md) | Test tiers, Headscale E2E, and live Tailscale suites |

## Why use it

- Build private app-to-app networking into Flutter and Dart applications.
- Use familiar package-native shapes: `http.Client`, request handlers, byte streams, datagrams, listeners, and small value types.
- Keep control-plane behavior in upstream Tailscale: auth, WireGuard, ACLs, MagicDNS, DERP, HTTPS certs, Serve, and Funnel policy.
- Avoid fake `dart:io.Socket` wrappers. Package-owned listeners use fd-backed local capabilities; forwarding APIs are reserved for local servers the application already owns.
- Test against Headscale locally and hosted Tailscale when a feature depends on Tailscale-only control-plane behavior.

## Install

```yaml
dependencies:
  tailscale: ^0.3.0
```

The first `dart run`, `dart test`, or `flutter build` triggers a native build hook that compiles the Go runtime for the target platform. Subsequent builds are cached and only recompile when Go source changes.

Prerequisites:

- Dart SDK 3.10 or newer.
- Go 1.25 or newer on `PATH`.
- Native toolchain for the target platform: Xcode for iOS/macOS, Android NDK through Flutter for Android, and a C toolchain for Linux.

## Quick start

```dart
import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  Tailscale.init(stateDir: '/app/state');

  final tailscale = Tailscale.instance;
  final status = await tailscale.up(
    hostname: 'dart-node',
    authKey: 'tskey-auth-...',
  );

  print('node: ${status.stableNodeId}');
  print('ipv4: ${status.ipv4}');
}
```

Subsequent launches can call `up()` without an auth key. The node identity is persisted in `stateDir`.

## Feature support

Area | API | Status | Notes
--- | --- | --- | ---
Lifecycle | `init`, `up`, `down`, `logout`, `status` | Supported | `up()` resolves on the first stable state: running, needs login, or needs machine auth.
Reactive state | `onStateChange`, `onError`, `onNodeChanges` | Supported | Go pushes updates to Dart; callers do not poll.
Node identity | `nodes`, `nodeByIp`, `whois` | Supported | Use stable node IDs for durable references.
Outbound HTTP | `http.client` | Supported | A normal `package:http` client routed through tsnet.
Inbound HTTP | `http.bind` | Supported | Package-native request/response types backed by fd streams.
Raw TCP | `tcp.dial`, `tcp.bind` | Supported | Explicit read/write halves and half-close.
Raw UDP | `udp.bind` | Supported | Message-preserving datagrams with remote endpoint metadata.
TLS listener | `tls.bind`, `tls.domains` | Supported | Requires MagicDNS and HTTPS enabled on the tailnet.
Serve | `serve.forward`, `serve.clear` | Supported | Tailnet-only publication for an existing loopback HTTP server.
Funnel | `funnel.forward`, `funnel.clear` | Supported | Public HTTPS publication through Tailscale Funnel policy.
Routing controls | `prefs`, `exitNode` | Supported | Subnet routes, Shields Up, tags, hostname, auto-update, and exit nodes.
Diagnostics | `diag` | Supported | Ping, metrics, DERP map, and update checks.
Taildrop | `taildrop` | Planned | Exported as a stub; not implemented in this release.
Profiles | `profiles` | Planned | Exported as a stub; not implemented in this release.
Windows | N/A | Unsupported | v1 is POSIX-only while the Windows data-plane backend is designed.

See [doc/api-status.md](doc/api-status.md) for the full namespace-by-namespace API map.

## Examples

A few canonical snippets below. The [developer site](https://danreynolds.github.io/tailscale_dart/#examples) hosts the full set covering raw TCP/UDP, TLS termination, Funnel, exit nodes, and routing controls; runnable variants live in [`example/`](example/).

All snippets assume the node has been initialized and started:

```dart
Tailscale.init(stateDir: '/app/state');
await Tailscale.instance.up(authKey: 'tskey-auth-...');
```

### Call a private HTTP service

`http.client` is a standard `package:http` client. Requests resolve MagicDNS and route through the embedded node.

```dart
final response = await Tailscale.instance.http.client.get(
  Uri.parse('http://api.tailnet.example.ts.net/health'),
);

if (response.statusCode != 200) {
  throw StateError('health check failed: ${response.statusCode}');
}
```

### Handle inbound HTTP directly

Use `http.bind` when the handler lives in this Dart process. No localhost proxy is opened.

```dart
final server = await Tailscale.instance.http.bind(port: 8080);

server.requests.listen((request) async {
  await request.respond(
    headers: {'content-type': 'text/plain; charset=utf-8'},
    body: 'hello from ${request.local.address}',
  );
});
```

### Reuse an existing Shelf or dart:io server

Use `serve.forward` when your app already owns a loopback HTTP server.

```dart
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  final localServer = await shelf_io.serve(
    (Request request) => Response.ok('served by Shelf'),
    InternetAddress.loopbackIPv4,
    3000,
  );

  final publication = await Tailscale.instance.serve.forward(
    tailnetPort: 443,
    localPort: localServer.port,
  );

  print('tailnet URL: ${publication.url}');
}
```

`funnel.forward` follows the same shape for public Funnel publication.

## Platform support

Platform | Status | Notes
--- | --- | ---
iOS | Supported | Userspace tsnet, no VPN entitlement. Validated with the Flutter smoke app.
Android | Supported | Userspace tsnet, no root. Validated with the Flutter smoke app.
macOS | Supported | Native asset and kqueue reactor path validated locally.
Linux | Supported | Native asset and epoll reactor path validated in Headscale E2E.
Windows | Unsupported | Excluded from the package platform list until a Windows-native backend is designed.

The package is intentionally POSIX-first because owned transports use native descriptors plus a shared kqueue/epoll reactor. Windows needs a different transport backend rather than a thin port of the POSIX implementation.

## Runtime model

```
Dart app
  |
  | typed API calls and streams
  v
FFI worker isolate
  |
  | control ops + fd-backed data-plane handoff
  v
Go tsnet runtime
  |
  | WireGuard, ACLs, MagicDNS, DERP
  v
Tailnet peers
```

Control-plane calls go through a worker isolate so Dart's main isolate does not block on native work. Runtime events come back through Dart ports as streams.

Owned transports (`http.bind`, `tcp.bind`, `udp.bind`, `tls.bind`) use private fd-backed capabilities. That keeps listener ownership inside the package and avoids pretending that a localhost proxy is secure. Forwarding APIs (`serve.forward`, `funnel.forward`) intentionally use loopback because their purpose is to publish an existing local HTTP server the application already owns.

## Testing

The repository keeps test tiers separate so common development remains fast while still supporting real network validation.

```bash
dart analyze
dart test
cd go && go test -count=1 ./...
tool/test_pr_gate.sh
```

Additional suites:

```bash
test/e2e/run_e2e.sh              # Headscale in Docker
tool/test_local_full.sh          # PR gate + package demos
tool/smoke/run_matrix.sh         # macOS/iOS/Android smoke matrix when devices are available
```

Live hosted-Tailscale tests are opt-in and require `TAILSCALE_API_KEY` and `TAILSCALE_TAILNET_ID`. They cover behavior Headscale does not model, such as HTTPS certificates, Funnel, and some exit-node policy flows. See [test/README.md](test/README.md) for the full breakdown.

## Roadmap

The core package path is implemented: lifecycle, node identity, HTTP, TCP, UDP, TLS, Serve/Funnel, prefs, exit nodes, diagnostics, Headscale E2E, and hosted-Tailscale live validation. Remaining launch and post-launch work is tracked in the design docs under [`doc/`](doc/) — see [Documentation](#documentation) for the index.

## License

[MIT](https://github.com/danReynolds/tailscale_dart/blob/main/LICENSE)
