# tailscale

Embed a full [Tailscale](https://tailscale.com) node in any Dart or Flutter app. Your app joins the tailnet, gets its own IP, reaches peers, and exposes a local HTTP server to the tailnet — all over encrypted WireGuard tunnels. No system `tailscaled` required.

This package runs one embedded node per process. It is designed for app-owned traffic, not system-wide VPN routing.

Works with [Tailscale](https://tailscale.com) and self-hosted [Headscale](https://github.com/juanfont/headscale).

```dart
Tailscale.init(stateDir: '/path/to/state');

final tsnet = Tailscale.instance;

final status = await tsnet.up(authKey: 'tskey-auth-...');

// Discover peers
final peer = (await tsnet.peers()).firstWhere((peer) => peer.online);

// Make requests — standard http.Client, routed through the tunnel
await tsnet.httpClient.get(Uri.parse('http://${peer.ipv4}/api/data'));

// Expose a local HTTP server to the tailnet
await tsnet.listen(localPort: 8080);
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
- **Outgoing requests** — `tsnet.httpClient` is a standard `http.Client` that routes through the WireGuard tunnel.
- **Incoming requests** — `tsnet.listen()` forwards tailnet HTTP traffic to your local server. Peer IP forwarded via `X-Dune-Peer-Ip` header.
- **Peer discovery** — `tsnet.peers()` returns typed peer snapshots, separate from lightweight node status.

**Real-time state updates**
- **Push channel** — Go pushes state transitions to Dart via NativePort. No polling.
- **`statusChanges` stream** — subscribe to pushed local-node `TailscaleStatus` snapshots after initialization.
- **`runtimeErrors` stream** — subscribe to typed asynchronous engine and watcher errors separately from call-specific exceptions.
- **`up()` waits for Running** — returns the current `TailscaleStatus` when the node is connected and ready for traffic, or throws on timeout.

**Developer experience**
- **Pure Dart** — no Flutter dependency. Works in Flutter apps, CLI tools, and server-side Dart.
- **Zero jank** — every FFI call runs on a background isolate. The main isolate is never blocked.
- **Automatic builds** — a Dart build hook compiles Go from source for the target platform. Add the dependency, have Go installed, done.
- **Headscale support** — configurable control URL. Tested end-to-end against Headscale in CI.

**Reliability**
- **Persistent auth** — machine keys stored in SQLite. Reconnects instantly on subsequent launches without an auth key.
- **Up timeout** — configurable timeout with clear error if the control server is unreachable.
- **Log control** — `Tailscale.init(logLevel: TailscaleLogLevel.info)` enables verbose native logs when you need them.
- **Tested** — unit, FFI integration, and full E2E tests against a real Headscale server, all running in CI.

## Usage

```dart
import 'package:tailscale/tailscale.dart';

// 1. Configure once at app startup
Tailscale.init(
  stateDir: '/path/to/state',
  logLevel: TailscaleLogLevel.info,
);

final tsnet = Tailscale.instance;
tsnet.statusChanges.listen((status) {
  print('Node state: ${status.nodeStatus}');
});
tsnet.runtimeErrors.listen((error) {
  print('Tailscale runtime error [${error.code.name}]: ${error.message}');
});

// status() / statusChanges are local-node snapshots.
// Fetch peers explicitly when your app needs peer inventory.
final peers = await tsnet.peers();
print('Known peers: ${peers.length}');

// 2. Bring the node up
//    First launch — provide an auth key to register
final status = await tsnet.up(authKey: 'tskey-auth-...');

//    Subsequent launches — just bring it up, reconnects from stored state
await tsnet.up();

// up() returns the current status once the node is Running.

// 3. Make requests to peers
final peer = (await tsnet.peers()).firstWhere((peer) => peer.online);
final response = await tsnet.httpClient.get(
  Uri.parse('http://${peer.ipv4}/api/data'),
);

// 4. Accept incoming HTTP requests from peers
await tsnet.listen(localPort: 8080);  // tailnet:80 → localhost:8080

// 5. Disconnect but keep identity
await tsnet.down();

// 6. Fully remove identity and stored state
await tsnet.logout();
```

## API

### `Tailscale`

| Member | Type | Description |
|--------|------|-------------|
| `init({stateDir, logLevel})` | `static void` | Configure once at startup. Stores state in `stateDir/tailscale/`. Repeated calls must use the same config. |
| `instance` | `static Tailscale` | Singleton accessor |
| `up({hostname, authKey, controlUrl, timeout})` | `Future<TailscaleStatus>` | Connect to the tailnet. Returns the current status when Running. |
| `listen({localPort, tailnetPort})` | `Future<int>` | Expose a local HTTP server to peers |
| `status()` | `Future<TailscaleStatus>` | Current local-node status snapshot (state, IPs, health) |
| `peers()` | `Future<List<PeerStatus>>` | Current peer snapshot for the tailnet |
| `statusChanges` | `Stream<TailscaleStatus>` | Pushed local-node status snapshots on state changes (without peers) |
| `runtimeErrors` | `Stream<TailscaleRuntimeError>` | Pushed asynchronous runtime errors |
| `down()` | `Future<void>` | Disconnect (preserves state for reconnection) |
| `logout()` | `Future<void>` | Disconnect and clear persisted state |
| `httpClient` | `http.Client` | HTTP client routed through the WireGuard tunnel |
| `isRunning` | `bool` | Whether the node is connected |

### `TailscaleStatus`

A snapshot of the local node's current state. Returned by `up()`/`status()` and pushed to `statusChanges`.

Peer inventory is intentionally not part of `TailscaleStatus`; call `peers()`
when your app needs the current peer snapshot.

| Member | Type | Description |
|--------|------|-------------|
| `nodeStatus` | `NodeStatus` | Where the node is in the connection lifecycle |
| `authUrl` | `Uri?` | Login URL to open when authentication is required |
| `tailscaleIPs` | `List<String>` | This node's assigned Tailscale IPs |
| `ipv4` | `String?` | This node's IPv4 address |
| `health` | `List<String>` | Health warnings (empty = healthy) |
| `magicDNSSuffix` | `String?` | The tailnet's MagicDNS suffix |
| `isRunning` | `bool` | Whether node status is `running` |
| `needsLogin` | `bool` | Whether node status is `needsLogin` |
| `isHealthy` | `bool` | Whether all health checks pass |

### `NodeStatus`

The node's position in the connection lifecycle. Matches Go's `ipn.State`.

| Value | Description |
|-------|-------------|
| `noState` | Engine created, hasn't started connecting |
| `needsLogin` | Needs authentication — provide an auth key via `up()` |
| `needsMachineAuth` | Authenticated, waiting for admin approval |
| `starting` | Connecting to the tailnet |
| `running` | Connected and ready for traffic |
| `stopped` | Shut down |

### `TailscaleLogLevel`

Controls native log verbosity for the embedded runtime.

| Value | Description |
|-------|-------------|
| `silent` | No native logs |
| `error` | Errors only |
| `info` | Informational and error logs |

### `TailscaleRuntimeError`

Typed asynchronous background error from the embedded runtime. Pushed through
`runtimeErrors`.

| Member | Type | Description |
|--------|------|-------------|
| `message` | `String` | Human-readable native runtime error |
| `code` | `TailscaleRuntimeErrorCode` | High-level error category |

### `PeerStatus`

A peer on the tailnet. Matches Go's `ipnstate.PeerStatus`.

| Member | Type | Description |
|--------|------|-------------|
| `publicKey` | `String` | Peer's public key |
| `hostName` | `String` | Peer's hostname on the tailnet |
| `dnsName` | `String` | Peer's MagicDNS name (may be fully-qualified with a trailing dot) |
| `os` | `String` | Peer's operating system |
| `tailscaleIPs` | `List<String>` | Peer's assigned IPs |
| `ipv4` | `String?` | Peer's IPv4 address |
| `online` | `bool` | Whether the peer is online |
| `active` | `bool` | Heuristic flag indicating recent/active traffic to the peer |
| `rxBytes` / `txBytes` | `int` | Traffic counters |
| `lastSeen` | `DateTime?` | When the peer was last seen (most useful for offline peers) |
| `relay` | `String?` | DERP relay region code (null if direct) |
| `curAddr` | `String?` | Current direct address for diagnostics (null if relayed) |

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
│  Dart app    │ ◄────────────► │  Go (tsnet)   │ ◄──── WireGuard ───► │  Peers      │
│              │  Isolate.run()  │  C exports    │      tunnel          │             │
│              │  NativePort     │  WatchIPNBus  │                      │             │
└─────────────┘                  └──────────────┘                       └─────────────┘
```

The Go layer wraps `tailscale.com/tsnet` and compiles to a platform-specific native library. A Dart [build hook](hook/build.dart) handles compilation automatically — detecting the target OS and architecture, finding the Go toolchain, cross-compiling with the appropriate flags (NDK for Android, Xcode for iOS), and registering the result as a native code asset.

Dart → Go calls use `@Native` FFI annotations and run on background isolates so the main isolate is never blocked.

Go → Dart notifications use NativePort (`Dart_PostCObject_DL`) to push state transitions from Go's `WatchIPNBus` goroutine directly to Dart's event loop — no polling.

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

The E2E tests start a [Headscale](https://github.com/juanfont/headscale) control server in Docker, create an ephemeral auth key, connect a real embedded node, verify IP assignment and peer discovery, then clean up. No Tailscale account needed.
