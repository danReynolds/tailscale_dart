# tailscale

A pure Dart package that embeds [Tailscale](https://tailscale.com) userspace networking via Go's `tsnet` library. It lets any Dart or Flutter application join a Tailscale network, reach peers over an encrypted WireGuard tunnel, and accept incoming connections — all without requiring a system-level Tailscale client (No Tailscale app required!).


## Features

- **Outgoing HTTP proxy** — reach any peer via a local proxy. Standard `http.Client` just works.
- **Reverse proxy** — expose a local Dart server to the tailnet. Peer IP forwarded in the `X-Dune-Peer-Ip` header.
- **Peer discovery** — list online peers and their IPs.
- **Persistent auth** — machine keys stored in SQLite. Reconnection is instant after first login.
- **Pure Dart** — no Flutter dependency. Works in Flutter apps, CLI tools, and server-side Dart.
- **Non-blocking** — all FFI calls run on background isolates. Main isolate is never blocked.
- **All platforms** — iOS, Android, macOS, Linux, Windows.
- **Automatic native build** — a Dart build hook compiles the Go library automatically. No manual build steps.

Your app becomes a first-class node on the Tailscale network. It gets its own IP, can reach other nodes, and other nodes can reach it — with full WireGuard encryption and Tailscale ACLs. Works with Tailscale's hosted control plane or self-hosted [Headscale](https://github.com/juanfont/headscale).

## API

| Method | Returns | Description |
|--------|---------|-------------|
| `init(clientId, authKey, controlUrl, stateDir, {timeout})` | `Future<void>` | Connect to a Tailscale/Headscale network |
| `getProxyUri(targetIp, path, {targetPort})` | `Uri` | Build a proxy URL to reach a peer (sync, pure Dart) |
| `startReverseProxy(localPort)` | `Future<void>` | Listen on tailnet port 80, forward to local port |
| `getPeerAddresses()` | `Future<List<String>>` | Online peer IPv4 addresses |
| `getLocalIP()` | `Future<String?>` | This node's Tailscale IPv4 address |
| `getStatus()` | `Future<String>` | Full Tailscale status as raw JSON |
| `getTypedStatus()` | `Future<TailscaleStatus>` | Parsed status with typed fields |
| `statusStream` | `Stream<TailscaleStatus>` | Reactive stream of status changes |
| `isProvisioned(stateDir)` | `Future<bool>` | Whether a valid machine key exists |
| `stop()` | `Future<void>` | Disconnect, preserve state |
| `logout(stateDir)` | `Future<void>` | Disconnect and delete all state |
| `setLogLevel(level)` | `void` | Set native log verbosity (0=silent, 1=errors, 2=info) |

All methods except `getProxyUri` and `setLogLevel` run on background isolates and return Futures.

## Usage

```dart
import 'package:tailscale/tailscale.dart';

final tsnet = DuneTsnet.instance;

// Join a Tailscale network from your app
await tsnet.init(
  clientId: 'my-app',
  authKey: 'tskey-auth-...',
  controlUrl: 'https://controlplane.tailscale.com',
  stateDir: '/path/to/state',
);

// Reach any device on your tailnet
final uri = tsnet.getProxyUri('100.64.0.5', '/api/data');
final response = await http.get(uri);

// Accept incoming traffic from the tailnet
await tsnet.startReverseProxy(8080);  // tailnet:80 → localhost:8080

// Discover peers on the network
final peers = await tsnet.getPeerAddresses();  // ['100.64.0.5', '100.64.0.6']
final myIp = await tsnet.getLocalIP();         // '100.64.0.2'
```

## How it works

```
┌─────────────┐       FFI        ┌──────────────┐      Tailscale       ┌─────────────┐
│  Dart app    │ ──────────────> │  Go (tsnet)   │ ◄──── WireGuard ───► │  Peers      │
│              │  Isolate.run()  │  C exports    │      tunnel          │             │
└─────────────┘                  └──────────────┘                       └─────────────┘
```

The Go layer compiles to a platform-specific native library (`.dylib`, `.so`, `.dll`, or static `.a` for iOS). A Dart [build hook](hook/build.dart) compiles the Go code automatically during `dart run` or `flutter build` — no manual build steps needed. Dart loads the result via `@Native` FFI annotations and runs every call on a background isolate so the main isolate is never blocked.

## Installation

### Prerequisites

- **Dart SDK** 3.10.4+ (or Flutter 3.41+)
- **[Go](https://go.dev/dl/)** 1.25+ — the build hook compiles Go automatically but needs the toolchain installed
- For **Android**: Android NDK (install via `sdkmanager --install "ndk;<version>"`)
- For **iOS**: Xcode with command-line tools

### Setup

Add to your `pubspec.yaml`:

```yaml
dependencies:
  tailscale:
    path: packages/tailscale  # or your path
```

That's it. The first `dart run`, `dart test`, or `flutter build` triggers the build hook which:

1. Finds Go on your system (PATH, GOROOT, or common install locations)
2. Verifies Go 1.25+
3. Cross-compiles for the target platform and architecture
4. Registers the native library as a code asset
5. Caches the result — rebuilds only when Go source files change

### Android

Your app's `AndroidManifest.xml` must include the network permission:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### iOS

The native library targets iOS 13.0+. Ensure your app's deployment target in Xcode is set to 13.0 or higher.

## Testing

### Unit tests

Tests pure Dart logic — URI generation, JSON parsing, state management:

```bash
cd packages/tailscale
dart test test/tailscale_test.dart
```

### Go tests

Tests the Go layer — SQLite state store, proxy handlers, error formatting, concurrency:

```bash
cd packages/tailscale/go
go test -v ./...
```

### FFI integration tests

Tests the real FFI boundary — symbol resolution, HasState against SQLite, error paths. The build hook compiles the native library automatically:

```bash
cd packages/tailscale
dart test test/ffi_integration_test.dart
```

### End-to-end tests

Full lifecycle test against a [Headscale](https://github.com/juanfont/headscale) control server running in Docker. Tests init, authentication, IP assignment, peer discovery, status, stop, and logout:

```bash
cd packages/tailscale
test/e2e/run_e2e.sh
```

This script starts a Headscale container, creates a test user and ephemeral auth key, runs the Dart E2E test suite, and tears down the container on exit. No Tailscale account needed.

### All tests

| Suite | Command | Requirements |
|-------|---------|-------------|
| Dart unit | `dart test test/tailscale_test.dart` | Dart SDK + Go |
| Go unit | `cd go && go test ./...` | Go |
| FFI integration | `dart test test/ffi_integration_test.dart` | Dart SDK + Go |
| E2E | `test/e2e/run_e2e.sh` | Dart SDK + Go + Docker |

## Platform support

| Platform | Build mode | Library format |
|----------|-----------|---------------|
| macOS | c-shared | `libtailscale.dylib` |
| Linux | c-shared | `libtailscale.so` |
| Windows | c-shared | `tailscale.dll` |
| Android | c-shared | `libtailscale.so` (per ABI) |
| iOS | c-archive | `libtailscale.a` (static) |

All platforms are handled automatically by the build hook. Android cross-compilation uses the NDK toolchain, iOS uses the Xcode toolchain.
