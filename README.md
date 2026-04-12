# tailscale

Embed a full [Tailscale](https://tailscale.com) node in any Dart or Flutter app. Your app joins the tailnet, gets its own IP, reaches peers, and accepts incoming connections — all over encrypted WireGuard tunnels. No Tailscale app required.

Works with [Tailscale](https://tailscale.com) and self-hosted [Headscale](https://github.com/juanfont/headscale).

```dart
Tailscale.init(stateDir: '/path/to/state');

final tsnet = Tailscale.instance;

// Join a tailnet
await tsnet.start(authKey: 'tskey-auth-...');

// Discover peers
final status = await tsnet.status();
final peer = status.onlinePeers.first;

// Make requests — just a standard http.Client
final response = await tsnet.http.get(Uri.parse('http://${peer.ipv4}/api/data'));

// Accept incoming traffic
await tsnet.listen(port: 8080);
```

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| iOS | Full support | No VPN entitlement needed |
| Android | Full support | Userspace mode, no root required |
| macOS | Full support | |
| Linux | Full support | |
| Windows | Full support | |

All platforms build automatically via a Dart [build hook](hook/build.dart) — no manual compilation, no pre-built binaries to manage.

## Features

**Networking**
- **Outgoing requests** — `tsnet.http` is a standard `http.Client` that routes through the WireGuard tunnel. Use it like any HTTP client.
- **Incoming requests** — `tsnet.listen()` forwards tailnet traffic to your local server. Peer IP forwarded via `X-Dune-Peer-Ip` header.
- **Peer discovery** — `tsnet.status()` returns typed status with online peers, local IP, health, and backend state.

**Developer experience**
- **Pure Dart** — no Flutter dependency. Works in Flutter apps, CLI tools, and server-side Dart.
- **Zero jank** — every FFI call runs on a background isolate. The main isolate is never blocked.
- **Automatic builds** — a Dart build hook compiles Go from source for the target platform. Add the dependency, have Go installed, done.
- **Headscale support** — configurable control URL. Tested end-to-end against Headscale in CI.

**Reliability**
- **Persistent auth** — machine keys stored in SQLite. Reconnects instantly on subsequent launches without an auth key.
- **Start timeout** — configurable timeout prevents hanging if the control server is unreachable.
- **Log control** — configure via `Tailscale.init(logLevel: 2)` for verbose output, or `0` (default) for silence.
- **Tested** — unit, FFI integration, and full E2E tests against a real Headscale server, all running in CI.

## Usage

```dart
import 'package:tailscale/tailscale.dart';

// 1. Configure once at app startup
Tailscale.init(stateDir: '/path/to/state');

final tsnet = Tailscale.instance;

// 2. Connect to the tailnet
//    First launch: provide an auth key to register
await tsnet.start(authKey: 'tskey-auth-...');

//    Subsequent launches: just start — reconnects from stored state
await tsnet.start();

// 3. Make requests to peers
final response = await tsnet.http.get(Uri.parse('http://100.64.0.5/api/data'));

// 4. Accept incoming requests from peers
await tsnet.listen(port: 8080);  // tailnet:80 → localhost:8080

// 5. Check status
final status = await tsnet.status();
print('IP: ${status.ipv4}');
print('Peers: ${status.onlinePeers.length}');
print('Running: ${status.isRunning}');
print('Healthy: ${status.isHealthy}');

// 6. Disconnect
await tsnet.close();
// To fully reset (switch tailnets), delete the stateDir after closing.
```

## API

### `Tailscale`

| Member | Type | Description |
|--------|------|-------------|
| `init({stateDir, logLevel})` | `static void` | Configure once at startup |
| `instance` | `static Tailscale` | Singleton accessor |
| `start({nodeName, authKey, controlUrl, timeout})` | `Future<void>` | Connect to the tailnet |
| `listen({port})` | `Future<int>` | Accept incoming traffic from peers |
| `status()` | `Future<TailscaleStatus>` | Current status (peers, IPs, health) |
| `isProvisioned()` | `Future<bool>` | Whether stored credentials exist |
| `close()` | `Future<void>` | Disconnect (preserves state) |
| `http` | `http.Client` | HTTP client routed through the tunnel |
| `proxyPort` | `int` | Local proxy port (for advanced use) |
| `isRunning` | `bool` | Whether the node is connected |

### `TailscaleStatus`

| Member | Type | Description |
|--------|------|-------------|
| `backendState` | `String` | "Running", "NeedsLogin", "Stopped", etc. |
| `tailscaleIPs` | `List<String>` | This node's assigned IPs |
| `ipv4` | `String?` | This node's IPv4 address |
| `peers` | `List<PeerStatus>` | All peers on the tailnet |
| `onlinePeers` | `List<PeerStatus>` | Online peers only |
| `health` | `List<String>` | Health warnings (empty = healthy) |
| `isRunning` | `bool` | Whether backend state is "Running" |
| `isHealthy` | `bool` | Whether health is clean |

### `PeerStatus`

| Member | Type | Description |
|--------|------|-------------|
| `publicKey` | `String` | Peer's public key |
| `hostName` | `String` | Peer's hostname |
| `ipv4` | `String?` | Peer's IPv4 address |
| `online` | `bool` | Whether the peer is online |
| `rxBytes` / `txBytes` | `int` | Traffic counters |
| `lastSeen` | `DateTime?` | When the peer was last seen |
| `relay` | `String?` | DERP relay region (null if direct) |
| `curAddr` | `String?` | Direct address (null if relayed) |

## Installation

### Prerequisites

- **Dart SDK** 3.10.4+ (or Flutter 3.41+)
- **[Go](https://go.dev/dl/)** 1.25+

For mobile targets:
- **Android**: Android NDK (`sdkmanager --install "ndk;<version>"`)
- **iOS**: Xcode with command-line tools

### Setup

```yaml
dependencies:
  tailscale:
    git: https://github.com/danReynolds/tailscale_dart
```

The first `dart run`, `dart test`, or `flutter build` triggers the build hook which compiles Go for the target platform automatically. Subsequent builds are cached and only recompile when Go source files change.

### Android

Your app's `AndroidManifest.xml` must include:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### iOS

Deployment target must be iOS 13.0+.

## How it works

```
┌─────────────┐       FFI        ┌──────────────┐      Tailscale       ┌─────────────┐
│  Dart app    │ ──────────────> │  Go (tsnet)   │ ◄──── WireGuard ───► │  Peers      │
│              │  Isolate.run()  │  C exports    │      tunnel          │             │
└─────────────┘                  └──────────────┘                       └─────────────┘
```

The Go layer wraps `tailscale.com/tsnet` and compiles to a platform-specific native library. A Dart [build hook](hook/build.dart) handles compilation automatically — detecting the target OS and architecture, finding the Go toolchain, cross-compiling with the appropriate flags (NDK for Android, Xcode for iOS), and registering the result as a native code asset. Dart communicates with Go via `@Native` FFI annotations and runs every call on a short-lived background isolate so the main isolate is never blocked.

## Testing

```bash
# Unit tests (pure Dart logic)
dart test test/tailscale_test.dart

# Go tests (SQLite store, proxy handlers, concurrency)
cd go && go test -v ./...

# FFI integration tests (real native library, no network)
dart test test/ffi_integration_test.dart

# End-to-end tests (full lifecycle against Headscale in Docker)
test/e2e/run_e2e.sh
```

The E2E tests start a [Headscale](https://github.com/juanfont/headscale) control server in Docker, create an ephemeral auth key, connect a real tsnet node, verify IP assignment and peer discovery, then clean up. No Tailscale account needed.
