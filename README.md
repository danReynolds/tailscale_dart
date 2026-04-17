<img width="200" height="200" alt="flutter_tailscale" src="https://github.com/user-attachments/assets/56a2a857-c5e7-42eb-9366-506daa56c5f9" />


# Flutter + Tailscale

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Dart 3.10+](https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-brightgreen.svg)]()

Bring a Flutter or plain Dart app onto your tailnet as its own node — talk to peers, expose local services, and add private connectivity without a system-wide VPN.

Works with [Tailscale](https://tailscale.com) and self-hosted [Headscale](https://github.com/juanfont/headscale).

```dart
Tailscale.init(stateDir: '/path/to/state');

final tailscale = Tailscale.instance;

await tailscale.up(authKey: 'tskey-auth-...');

// Discover peers
final peers = await tailscale.peers(); // List<PeerStatus>
final peer = peers.firstWhere((peer) => peer.online);

// Make requests — standard http.Client, routed through the tunnel
await tailscale.http.get(Uri.parse('http://${peer.ipv4}/api/data'));

// Expose a local HTTP server to receive traffic from the tailnet
await tailscale.listen(8080);
```

### Install

```yaml
dependencies:
  tailscale: ^0.1.0
```

The first `dart run`, `dart test`, or `flutter build` triggers a [build hook](hook/build.dart) that compiles Go for the target platform automatically. Subsequent builds are cached and only recompile when Go source changes.

## Features

- **App-scoped networking** — your app joins the tailnet itself instead of depending on a separate VPN
- **Familiar HTTP client** — standard [`http.Client`](https://pub.dev/documentation/http/latest/http/Client-class.html) routed through [WireGuard](https://www.wireguard.com/)
- **Inbound HTTP publishing** — expose a local server to tailnet peers with `listen()`
- **Typed runtime state** — observe node status, peers, and errors through Dart models
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

// 3. Make requests to peers
final peers = await tailscale.peers();
final peer = peers.firstWhere((p) => p.online);

final response = await tailscale.http.get(
  Uri.parse('http://${peer.ipv4}/api/data'),
);

// 4. Accept incoming HTTP requests from peers
await tailscale.listen(8080); // tailnet:80 -> localhost:8080

// 5. Disconnect (keeps identity)
await tailscale.down();

// 6. Disconnect and fully remove state
await tailscale.logout();
```

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| iOS | Full support | No VPN entitlement needed |
| Android | Full support | Userspace mode, no root required |
| macOS | Full support | |
| Linux | Full support | |
| Windows | Full support | |

## API

| Member | Type | Description |
|--------|------|-------------|
| `init({stateDir, logLevel})` | `static void` | Configure once at startup. Stores state in `stateDir/tailscale/`. |
| `instance` | `static Tailscale` | Singleton accessor |
| `up({hostname, authKey, controlUrl})` | `Future<void>` | Start the node. Subscribe to `onStateChange` to observe when it reaches Running. |
| `listen(localPort, {tailnetPort})` | `Future<int>` | Expose a local HTTP server to peers |
| `status()` | `Future<TailscaleStatus>` | Current local-node snapshot (state, IPs, health). Before `up()`, returns `stopped` or `noState` based on whether persisted credentials exist. |
| `peers()` | `Future<List<PeerStatus>>` | Current peer snapshot |
| `onStateChange` | `Stream<NodeState>` | Pushed lifecycle state changes |
| `onError` | `Stream<TailscaleRuntimeError>` | Pushed asynchronous runtime errors |
| `down()` | `Future<void>` | Disconnect (preserves state for reconnection) |
| `logout()` | `Future<void>` | Disconnect and clear persisted state |
| `http` | [`http.Client`](https://pub.dev/documentation/http/latest/http/Client-class.html) | HTTP client routed through the WireGuard tunnel |

<details>
<summary><strong>TailscaleStatus</strong></summary>

A snapshot of the local node's current state. Returned by `status()`. Peer inventory is separate — call `peers()` when you need it.

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
<summary><strong>PeerStatus</strong></summary>

A peer on the tailnet. Matches Go's [`ipnstate.PeerStatus`](https://pkg.go.dev/tailscale.com/ipnstate#PeerStatus).

| Member | Type | Description |
|--------|------|-------------|
| `publicKey` | `String` | Peer's public key |
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
│  Dart app   │ <─────────────> │  Go (tsnet)  │ <─── WireGuard ────> │  Peers      │
│             │  Isolate.run()  │  C exports   │      tunnel          │             │
│             │  NativePort     │  WatchIPNBus │                      │             │
└─────────────┘                 └──────────────┘                      └─────────────┘
```

The Go layer wraps [`tailscale.com/tsnet`](https://pkg.go.dev/tailscale.com/tsnet) and compiles to a platform-specific native library. A Dart [build hook](hook/build.dart) handles compilation — detecting the target OS/architecture, finding the Go toolchain, cross-compiling with the appropriate flags, and registering the result as a [native code asset](https://dart.dev/interop/c-interop#native-assets).

**Dart -> Go** calls use [`@Native`](https://api.dart.dev/dart-ffi/Native-class.html) FFI annotations and run on background isolates so the main isolate is never blocked.

**Go -> Dart** notifications use [`NativePort`](https://api.dart.dev/dart-isolate/SendPort/nativePort.html) to push state transitions from Go's `WatchIPNBus` goroutine directly to Dart's event loop.

## Testing

```bash
dart test test/tailscale_test.dart              # Unit tests
cd go && go test -v ./...                       # Go tests
dart test test/ffi_integration_test.dart         # FFI integration tests
test/e2e/run_e2e.sh                             # E2E against Headscale in Docker
```

The E2E suite starts a [Headscale](https://github.com/juanfont/headscale) server in Docker, creates an ephemeral auth key, connects a real embedded node, verifies IP assignment and peer discovery, then cleans up. No Tailscale account needed.

## License

[MIT](LICENSE)
