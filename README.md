<img width="200" height="200" alt="flutter_tailscale" src="https://github.com/user-attachments/assets/56a2a857-c5e7-42eb-9366-506daa56c5f9" />


# Flutter + Tailscale

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart 3.10+](https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux-brightgreen.svg)]()

Bring a Flutter or plain Dart app onto your tailnet as its own node — talk to other nodes, expose local services, and add private connectivity without a system-wide VPN.

Works with [Tailscale](https://tailscale.com) and self-hosted [Headscale](https://github.com/juanfont/headscale).

```dart
Tailscale.init(stateDir: '/path/to/state');

final tailscale = Tailscale.instance;

await tailscale.up(authKey: 'tskey-auth-...');

// Discover nodes
final nodes = await tailscale.nodes(); // List<TailscaleNode>
final node = nodes.firstWhere((node) => node.online);

// Make requests — standard http.Client, routed through the tunnel
await tailscale.http.client.get(Uri.parse('http://${node.ipv4}/api/data'));

// Accept inbound HTTP requests on tailnet:80
final server = await tailscale.http.bind(port: 80);
server.requests.listen((request) async {
  await request.respond(body: 'hello from tailnet');
});
```

### Install

```yaml
dependencies:
  tailscale: ^0.3.0
```

The first `dart run`, `dart test`, or `flutter build` triggers a [build hook](hook/build.dart) that compiles Go for the target platform automatically. Subsequent builds are cached and only recompile when Go source changes.

## Features

- **App-scoped networking** — your app joins the tailnet itself instead of depending on a separate VPN
- **Familiar HTTP client** — standard [`http.Client`](https://pub.dev/documentation/http/latest/http/Client-class.html) routed through [WireGuard](https://www.wireguard.com/)
- **Inbound HTTP publishing** — accept tailnet HTTP requests directly with `http.bind()`
- **Serve/Funnel forwarding** — publish an existing loopback HTTP service inside the tailnet or on the public internet
- **Typed runtime state** — observe node status, node inventory, and errors through Dart models
- **Persistent identity** — reconnect across launches without re-authenticating
- **Automatic cross-platform builds** — Go layer compiles for the target via Dart [build hooks](https://dart.dev/tools/build-hooks)
- **Headscale compatible** — point the control plane at Tailscale or your own deployment
- **Real-time push notifications** — Go pushes state changes to Dart via [`NativePort`](https://api.dart.dev/dart-isolate/SendPort/nativePort.html), no polling

## Usage

```dart
import 'package:tailscale/tailscale.dart';

// 1. Configure once at app startup
Tailscale.init(
  stateDir: '/path/to/state',
  logLevel: TailscaleLogLevel.info,
);

final tailscale = Tailscale.instance;
tailscale.onStateChange.listen((state) => print('Node: $state'));
tailscale.onError.listen((e) => print('Error: ${e.message}'));

// 2. Bring the node up (first launch needs an auth key)
await tailscale.up(authKey: 'tskey-auth-...');

//    Subsequent launches reconnect from stored state
await tailscale.up();

// 3. Make requests to nodes
final nodes = await tailscale.nodes();
final node = nodes.firstWhere((p) => p.online);

final response = await tailscale.http.client.get(
  Uri.parse('http://${node.ipv4}/api/data'),
);

// 4. Accept incoming HTTP requests from nodes
final server = await tailscale.http.bind(port: 80);
server.requests.listen((request) async {
  await request.respond(body: 'hello from tailnet');
});

// 5. Disconnect (keeps identity)
await tailscale.down();

// 6. Disconnect and fully remove state
await tailscale.logout();
```

## Platform Support

This release is POSIX-only. The fd-backed data plane uses native descriptors
plus kqueue/epoll, so Android, iOS, macOS, and Linux are the supported platform
set. Windows is intentionally excluded until the project either designs a
Windows-native capability backend or chooses a separate Windows fallback.

| Platform | Status | Notes |
|----------|--------|-------|
| iOS | Supported | Manual demo validation passed for HTTP, TCP, and UDP. No VPN entitlement needed. |
| Android | Supported | Manual demo validation passed for HTTP, TCP, and UDP. Userspace mode, no root required. |
| macOS | Supported | Manual demo validation passed for HTTP, TCP, and UDP. |
| Linux | Supported | Ubuntu CI runs Headscale E2E, exercising the Linux native asset and epoll reactor path. |
| Windows | Unsupported | Not supported in v1. |

## API

| Member | Type | Description |
|--------|------|-------------|
| `init({stateDir, logLevel})` | `static void` | Configure once at startup. Stores state in `stateDir/tailscale/`. |
| `instance` | `static Tailscale` | Singleton accessor |
| `up({hostname, authKey, controlUrl, timeout})` | `Future<TailscaleStatus>` | Start the node and resolve on the first stable state. |
| `status()` | `Future<TailscaleStatus>` | Current local-node snapshot (state, IPs, health). Before `up()`, returns `stopped` or `noState` based on whether persisted credentials exist. |
| `nodes()` | `Future<List<TailscaleNode>>` | Current node snapshot |
| `nodeByIp(ip)` | `Future<TailscaleNode?>` | Lookup a known node by Tailscale IP |
| `onStateChange` | `Stream<NodeState>` | Pushed lifecycle state changes |
| `onError` | `Stream<TailscaleRuntimeError>` | Pushed asynchronous runtime errors |
| `down()` | `Future<void>` | Disconnect (preserves state for reconnection) |
| `logout()` | `Future<void>` | Disconnect and clear persisted state |
| `http.client` | [`http.Client`](https://pub.dev/documentation/http/latest/http/Client-class.html) | HTTP client routed through the WireGuard tunnel |
| `http.bind({port})` | `Future<TailscaleHttpServer>` | Accept tailnet HTTP requests as package-native request/response objects |
| `tcp.dial(host, port, {timeout})` | `Future<TailscaleConnection>` | Open a raw TCP byte stream to a tailnet node |
| `tcp.bind({port, address})` | `Future<TailscaleListener>` | Accept raw TCP connections from tailnet nodes |
| `tls.bind({port, address})` | `Future<TailscaleListener>` | Accept TLS-terminated tailnet connections as plaintext package-native streams |
| `tls.domains()` | `Future<List<String>>` | Auto-provisioned certificate SANs; empty when MagicDNS/HTTPS is disabled |
| `udp.bind({port, address})` | `Future<TailscaleDatagramBinding>` | Send and receive UDP datagrams on a tailnet IP |
| `serve.forward({tailnetPort, localPort})` | `Future<TailscalePublishedService>` | Publish an existing loopback HTTP service inside the tailnet |
| `funnel.forward({publicPort, localPort})` | `Future<TailscalePublishedService>` | Publish an existing loopback HTTP service through Tailscale Funnel |

The `taildrop` and `profiles` namespaces are declared and documented but throw `UnimplementedError` in this release — see [`docs/api-roadmap.md`](docs/api-roadmap.md) for the phased rollout plan.

## Transport Lifecycle

`tcp.bind()`, `tls.bind()`, and `http.bind()` allocate native listeners and
start background accept loops when their streams are listened to. Treat the returned
`TailscaleListener` / `TailscaleHttpServer` as the owner of the tailnet port:
call `close()` when finished. Canceling the single-subscription
`connections`/`requests` stream also closes the listener/server.

Accepted TCP/TLS connections and HTTP requests are delivered through bounded
local queues while the Dart subscription is paused. If the application stops
draining for long enough, overflow accepts are rejected or closed rather than
buffered without limit.

TCP connections expose separate read and write halves. `connection.input` is a
single-subscription byte stream. `connection.output.close()` half-closes the
write side and lets the app keep reading; `connection.close()` means the app is
done with the whole connection. `connection.abort()` is immediate teardown.

HTTP request bodies are also single-subscription streams. Consume
`request.body` once, or buffer explicitly in application code if multiple
layers need to inspect it. HTTP response headers can be set with
`response.setHeader(...)` or appended with `response.addHeader(...)` for
multi-value headers such as `set-cookie`.

`serve.forward(...)` and `funnel.forward(...)` are different from
`http.bind(...)`: they proxy to an existing local HTTP server, typically bound
to `127.0.0.1`. The target address must be loopback, which prevents
accidentally publishing arbitrary LAN or metadata-service endpoints. This is the
right shape for reusing Shelf or `dart:io` servers. `http.bind(...)` is stronger
when the handler lives inside this process because it avoids opening a loopback
TCP port at all. `funnel.forward` uses Tailscale's native Funnel listener for
the public edge and then proxies to the local server. Publications created by
this package are process-scoped: close the returned
`TailscalePublishedService` when done, and `down()` removes package-created
publications best-effort before stopping the embedded node.

## Validation Demo

The repo includes a reusable demo harness in
[`packages/demo_core`](packages/demo_core) and a Flutter validation app in
[`packages/demo_flutter`](packages/demo_flutter). The Flutter app can bring up a
node, expose HTTP/TCP/UDP echo services, list nodes, and probe another node from
macOS, iOS, or Android.

<details>
<summary><strong>TailscaleStatus</strong></summary>

A snapshot of the local node's current state. Returned by `status()`. Node inventory is separate — call `nodes()` when you need it.

| Member | Type | Description |
|--------|------|-------------|
| `state` | `NodeState` | Connection lifecycle state |
| `authUrl` | `Uri?` | Login URL when authentication is required |
| `tailscaleIPs` | `List<String>` | Assigned Tailscale IPs |
| `ipv4` | `String?` | IPv4 address |
| `health` | `List<String>` | Health warnings (empty = healthy) |
| `magicDNSSuffix` | `String?` | Tailnet's [MagicDNS](https://tailscale.com/kb/1081/magicdns) suffix |
| `isRunning` / `needsLogin` / `isHealthy` | `bool` | Convenience getters |

</details>

<details>
<summary><strong>NodeState</strong></summary>

The node's position in the connection lifecycle. Matches Go's [`ipn.State`](https://pkg.go.dev/tailscale.com/ipn#State).

| Value | Description |
|-------|-------------|
| `noState` | No persisted credentials, never authenticated |
| `needsLogin` | Needs authentication (credentials expired or first use) |
| `needsMachineAuth` | Authenticated, waiting for admin approval |
| `starting` | Connecting to the tailnet |
| `running` | Connected and ready for traffic |
| `stopped` | Engine not running, but persisted credentials exist |

</details>

<details>
<summary><strong>TailscaleNode</strong></summary>

A node on the tailnet. Parsed from Go's [`ipnstate.PeerStatus`](https://pkg.go.dev/tailscale.com/ipnstate#PeerStatus).

| Member | Type | Description |
|--------|------|-------------|
| `publicKey` | `String` | Node's public key |
| `hostName` / `dnsName` | `String` | Hostname and MagicDNS name |
| `os` | `String` | Operating system |
| `tailscaleIPs` | `List<String>` | Assigned IPs |
| `ipv4` | `String?` | IPv4 address |
| `online` / `active` | `bool` | Online status and traffic heuristic |
| `rxBytes` / `txBytes` | `int` | Traffic counters |
| `lastSeen` | `DateTime?` | Last seen timestamp |
| `relay` / `curAddr` | `String?` | [DERP](https://tailscale.com/kb/1232/derp-servers) relay or direct address |

</details>

<details>
<summary><strong>TailscaleRuntimeError &amp; TailscaleLogLevel</strong></summary>

**TailscaleRuntimeError** — typed background error pushed through `onError`.

| Member | Type | Description |
|--------|------|-------------|
| `message` | `String` | Human-readable error |
| `code` | `TailscaleRuntimeErrorCode` | Error category |

**TailscaleLogLevel** — controls native log verbosity.

| Value | Description |
|-------|-------------|
| `silent` | No native logs |
| `error` | Errors only |
| `info` | Informational and error logs |

</details>

## Architecture

```
┌─────────────┐       FFI       ┌──────────────┐      Tailscale       ┌─────────────┐
│  Dart app   │ <─────────────> │  Go (tsnet)  │ <─── WireGuard ────> │  Nodes      │
│             │  Isolate.run()  │  C exports   │      tunnel          │             │
│             │  NativePort     │  WatchIPNBus │                      │             │
└─────────────┘                 └──────────────┘                      └─────────────┘
```

The Go layer wraps [`tailscale.com/tsnet`](https://pkg.go.dev/tailscale.com/tsnet) and compiles to a platform-specific native library. A Dart [build hook](hook/build.dart) handles compilation — detecting the target OS/architecture, finding the Go toolchain, cross-compiling with the appropriate flags, and registering the result as a [native code asset](https://dart.dev/interop/c-interop#native-assets).

**Dart -> Go** calls use [`@Native`](https://api.dart.dev/dart-ffi/Native-class.html) FFI annotations and run on background isolates so the main isolate is never blocked.

**Go -> Dart** notifications use [`NativePort`](https://api.dart.dev/dart-isolate/SendPort/nativePort.html) to push state transitions from Go's `WatchIPNBus` goroutine directly to Dart's event loop.

## Testing

```bash
dart analyze                                     # Static analysis
dart test                                        # Unit + local integration tests
cd go && go test -count=1 ./...                  # Go tests
test/e2e/run_e2e.sh                              # E2E against Headscale in Docker
tool/test_pr_gate.sh                             # Local equivalent of required PR checks
tool/test_local_full.sh                          # PR gate + demo package tests
cd packages/demo_core && dart test --enable-experiment=native-assets
cd packages/demo_flutter && flutter test
```

The E2E suite starts a [Headscale](https://github.com/juanfont/headscale) server in Docker, creates an ephemeral auth key, connects a real embedded node, verifies IP assignment and node discovery, then cleans up. No Tailscale account needed.
See [docs/testing.md](docs/testing.md) for the test layout and placement rules.

## License

[MIT](LICENSE)
