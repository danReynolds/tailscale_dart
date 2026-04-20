# API status & usage

Reference for the public API surface of `package:tailscale`, grouped by
namespace. Tracks what works today versus what is typed-and-documented
but unimplemented. For the forward-looking phase plan, see
[`api-roadmap.md`](api-roadmap.md).

**Legend:**
- ✅ Working — callable today, tested, returns real values.
- ⛔ Stub — typed and documented, but throws `UnimplementedError`. Scheduled for a later phase.

## Namespace overview

| Namespace   | Purpose                                                                  | Status                               |
| ----------- | ------------------------------------------------------------------------ | ------------------------------------ |
| Lifecycle   | `init` / `up` / `down` / `logout` / `status` / `peers` + streams         | ✅ Working                            |
| `http`      | `http.Client` over the tailnet + reverse-proxy helper                    | ✅ Working                            |
| `tcp`       | Raw TCP `dial` / `bind` between tailnet peers                            | ⛔ Stub (Phase 3)                    |
| `tls`       | TLS-terminated listener with auto-provisioned cert                       | ⛔ Stub (Phase 4–5)                  |
| `udp`       | UDP datagram listener on a tailnet IP                                    | ⛔ Stub (Phase 5)                    |
| `funnel`    | Public-internet HTTPS via Tailscale Funnel                               | ⛔ Stub (Phase 5) — `FunnelMetadata` typed |
| `taildrop`  | Peer-to-peer file transfer                                               | ⛔ Stub (Phase 8)                    |
| `serve`     | `tailscale serve` / `tailscale funnel` config                             | ⛔ Stub (Phase 9)                    |
| `exitNode`  | Route outbound traffic through a peer                                     | ⛔ Stub (Phase 6)                    |
| `profiles`  | Multi-account / multi-tailnet                                             | ⛔ Stub (Phase 7)                    |
| `prefs`     | Subnet routes, shields, tags, auto-update                                | ⛔ Stub (Phase 6)                    |
| `diag`      | Ping, metrics, DERP map, update check                                     | ⛔ Stub (Phase 4, 10)                |
| `whois`     | Resolve a tailnet IP to peer identity (top-level)                         | ⛔ Stub (Phase 4)                    |

## Setup

```dart
import 'package:tailscale/tailscale.dart';

void main() async {
  Tailscale.init(stateDir: '/path/to/app/state');

  final tsnet = Tailscale.instance;
  final status = await tsnet.up(authKey: 'tskey-...');

  switch (status.state) {
    case NodeState.running:
      // Ready to send/receive.
    case NodeState.needsLogin:
      // Open status.authUrl in a browser/web view.
    case NodeState.needsMachineAuth:
      // Wait for admin approval in the control plane.
    default:
      // Transient; listen on onStateChange.
  }
}
```

## Lifecycle (top-level)

The engine lifecycle plus reactive streams. Nothing in here is namespaced — these live directly on `Tailscale.instance`.

| API                                           | Status | Purpose                                                                      |
| --------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `Tailscale.init({stateDir, logLevel})`         | ✅     | One-time library configuration at app startup.                               |
| `up({hostname, authKey, controlUrl})` → `TailscaleStatus` | ✅     | Start the engine; resolves on first stable state (running / needsLogin / needsMachineAuth). |
| `down()`                                      | ✅     | Stop the engine, keeping persisted credentials.                               |
| `logout()`                                    | ✅     | Stop + wipe persisted credentials.                                            |
| `status()` → `TailscaleStatus`                | ✅     | Snapshot of node state, IPs, health, MagicDNS suffix.                         |
| `peers()` → `List<PeerStatus>`                | ✅     | Current peer inventory.                                                       |
| `onStateChange` → `Stream<NodeState>`         | ✅     | Distinct-filtered state transitions.                                          |
| `onError` → `Stream<TailscaleRuntimeError>`   | ✅     | Async runtime errors pushed from Go.                                          |
| `onPeersChange` → `Stream<List<PeerStatus>>`  | ⛔     | Peer inventory changes without polling. *Phase 4.*                            |

```dart
final tsnet = Tailscale.instance;

tsnet.onStateChange.listen((state) => print('state: $state'));
tsnet.onError.listen((err) => print('runtime error: $err'));

final status = await tsnet.up(authKey: 'tskey-...');
print('IPs: ${status.tailscaleIPs}');

final peers = await tsnet.peers();
for (final peer in peers) {
  print('${peer.hostName} (${peer.stableNodeId}) online=${peer.online}');
}

await tsnet.down();
```

## `http`

HTTP conveniences over the tailnet. Call `Tailscale.instance.http.*`.

| API                                           | Status | Purpose                                                                      |
| --------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `http.client` → `http.Client`                 | ✅     | Drop-in `http.Client` that tunnels every request over the tailnet.           |
| `http.expose(localPort, {tailnetPort})` → `int` | ✅     | Reverse-proxy helper: forward tailnet traffic on `tailnetPort` to `localhost:localPort`. Returns the effective local port. |

```dart
// Call a peer's HTTP API.
final response = await tsnet.http.client.get(
  Uri.parse('http://100.64.0.5/api/status'),
);
print(response.body);

// Publish your local HTTP server on the tailnet.
final server = await HttpServer.bind('127.0.0.1', 0);
await tsnet.http.expose(server.port, tailnetPort: 80);
```

## `tcp`

Raw TCP primitives over the tailnet. Returns standard `dart:io` types.

| API                                                | Status | Purpose                                                                 |
| -------------------------------------------------- | ------ | ----------------------------------------------------------------------- |
| `tcp.dial(host, port, {timeout})` → `Socket`       | ⛔     | Outbound connection to a tailnet peer. Wraps `tsnet.Server.Dial`.        |
| `tcp.bind(port, {host})` → `ServerSocket`          | ⛔     | Accept inbound TCP on the tailnet. Wraps `tsnet.Server.Listen`.          |

```dart
// Outbound.
final socket = await tsnet.tcp.dial('100.64.0.5', 22);
socket.add(utf8.encode('hello'));
await socket.flush();

// Inbound.
final server = await tsnet.tcp.bind(1234);
await for (final conn in server) {
  conn.pipe(conn); // echo
}
```

## `tls`

TLS-terminated listener with a cert auto-provisioned by the control
plane. Requires the tailnet operator to have enabled MagicDNS + HTTPS.

| API                                               | Status | Purpose                                                                |
| ------------------------------------------------- | ------ | ---------------------------------------------------------------------- |
| `tls.bind(port)` → `SecureServerSocket`           | ⛔     | Accept TLS-terminated connections; cert provisioned automatically.      |
| `tls.domains()` → `List<String>`                  | ⛔     | Cert SANs; preflight for `tls.bind`.                                    |

```dart
final server = await tsnet.tls.bind(443);
await for (final conn in server) {
  // conn is a plaintext Socket — TLS was terminated upstream.
  conn.writeln('HTTP/1.1 200 OK\r\n\r\nhello');
  await conn.close();
}
```

## `udp`

UDP datagram sockets over the tailnet.

| API                                             | Status | Purpose                                                               |
| ----------------------------------------------- | ------ | --------------------------------------------------------------------- |
| `udp.bind(host, port)` → `RawDatagramSocket`    | ⛔     | Bind a UDP socket on a specific tailnet IP of this node.              |

```dart
final ip = (await tsnet.status()).ipv4!;
final sock = await tsnet.udp.bind(ip, 4000);
sock.listen((event) {
  if (event == RawSocketEvent.read) {
    final dg = sock.receive();
    print('from ${dg?.address}: ${utf8.decode(dg!.data)}');
  }
});
```

## `funnel`

Public-internet HTTPS via Tailscale Funnel. Requires the tailnet
operator to have enabled Funnel in ACLs for this node.

| API                                                      | Status | Purpose                                                        |
| -------------------------------------------------------- | ------ | -------------------------------------------------------------- |
| `funnel.bind(port, {funnelOnly})` → `SecureServerSocket` | ⛔     | Public-internet TLS listener at the node's Funnel hostname.    |
| `FunnelMetadata`                                         | ✅     | Value type exposing `publicSrc` + `sni` observed by the Funnel edge. |
| `Socket.funnel` extension                                | ✅     | Read `FunnelMetadata` off an accepted socket, or null if not from Funnel. |

```dart
final server = await tsnet.funnel.bind(443);
await for (final conn in server) {
  final meta = conn.funnel;
  if (meta != null) {
    print('public src: ${meta.publicSrc}, sni: ${meta.sni}');
  }
  conn.writeln('HTTP/1.1 200 OK\r\n\r\nhello world');
  await conn.close();
}
```

## `taildrop`

Peer-to-peer file transfer over the tailnet. Sends go directly between
nodes with no intermediary.

| API                                                              | Status | Purpose                                                             |
| ---------------------------------------------------------------- | ------ | ------------------------------------------------------------------- |
| `taildrop.targets()` → `List<FileTarget>`                        | ⛔     | Peers eligible to receive files right now.                           |
| `taildrop.push({target, name, data, size?})`                     | ⛔     | Stream a file to a peer.                                             |
| `taildrop.waitingFiles()` → `List<WaitingFile>`                  | ⛔     | Received files not yet picked up.                                    |
| `taildrop.awaitWaitingFiles({timeout})` → `List<WaitingFile>`    | ⛔     | Block until at least one file is available or the timeout fires.      |
| `taildrop.openRead(name)` → `Stream<Uint8List>`                  | ⛔     | Byte-stream a received file (caller owns persistence).               |
| `taildrop.delete(name)`                                          | ⛔     | Discard a received file without reading it.                          |
| `taildrop.onWaitingFile` → `Stream<WaitingFile>`                 | ⛔     | Reactive version of `awaitWaitingFiles`.                              |
| `FileTarget`                                                     | ✅     | Value type: peer identity + hostname.                                 |
| `WaitingFile`                                                    | ✅     | Value type: name + size.                                              |

```dart
// Send.
final targets = await tsnet.taildrop.targets();
final peer = targets.firstWhere((t) => t.hostname == 'laptop');
await tsnet.taildrop.push(
  target: peer,
  name: 'report.pdf',
  data: File('/tmp/report.pdf').openRead().cast<Uint8List>(),
);

// Receive.
await for (final file in tsnet.taildrop.onWaitingFile) {
  final bytes = await tsnet.taildrop.openRead(file.name)
      .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
  await File('/downloads/${file.name}').writeAsBytes(bytes);
  await tsnet.taildrop.delete(file.name);
}
```

## `serve`

`tailscale serve` / `tailscale funnel` configuration — HTTP/TCP routing
and public-internet publishing.

| API                                    | Status | Purpose                                                                  |
| -------------------------------------- | ------ | ------------------------------------------------------------------------ |
| `serve.getConfig()` → `ServeConfig`    | ⛔     | Current serve/funnel config for this node.                                |
| `serve.setConfig(ServeConfig)`         | ⛔     | Replace atomically; throws on `ServeConfig.etag` mismatch.                |
| `ServeConfig` (with `etag`)            | ✅     | Value type for optimistic concurrency. Handler modeling lands in Phase 9. |

```dart
final config = await tsnet.serve.getConfig();
final updated = config.addWebMount('/docs', DirectoryHandler('/var/www/docs'));

try {
  await tsnet.serve.setConfig(updated);
} on TailscaleServeException catch (e) when e.code == TailscaleErrorCode.conflict {
  // Someone else changed it; re-fetch and retry.
}
```

## `exitNode`

Route all outbound traffic from this node through a peer (VPN-style).

| API                                                        | Status | Purpose                                                                |
| ---------------------------------------------------------- | ------ | ---------------------------------------------------------------------- |
| `exitNode.current()` → `PeerStatus?`                       | ⛔     | Peer currently used as exit, or null.                                   |
| `exitNode.suggest()` → `PeerStatus?`                       | ⛔     | Control-plane-recommended exit node (latency-based).                     |
| `exitNode.use(PeerStatus)`                                 | ⛔     | Route through this peer. Type-safe.                                      |
| `exitNode.useById(String stableNodeId)`                    | ⛔     | Escape hatch when only the stable ID is available.                       |
| `exitNode.useAuto()`                                       | ⛔     | `AutoExitNode` mode — control plane picks (and re-picks).                 |
| `exitNode.clear()`                                         | ⛔     | Stop using any exit node.                                                |
| `exitNode.onCurrentChange` → `Stream<PeerStatus?>`         | ⛔     | React to exit-node changes (including external).                         |

```dart
final suggested = await tsnet.exitNode.suggest();
if (suggested != null) {
  await tsnet.exitNode.use(suggested);
}

tsnet.exitNode.onCurrentChange.listen((peer) {
  print('now routing via ${peer?.hostName ?? "direct"}');
});
```

## `profiles`

Multi-account / multi-tailnet: one device, several identities.

| API                                            | Status | Purpose                                                              |
| ---------------------------------------------- | ------ | -------------------------------------------------------------------- |
| `profiles.current()` → `LoginProfile?`         | ⛔     | Currently active profile, or null on a fresh install.                  |
| `profiles.list()` → `List<LoginProfile>`       | ⛔     | All profiles persisted on this node.                                   |
| `profiles.switchTo(LoginProfile)`              | ⛔     | Disconnect + reconnect with the target profile's credentials.          |
| `profiles.switchToId(String id)`               | ⛔     | Escape hatch when only the ID is known.                                |
| `profiles.delete(LoginProfile)`                | ⛔     | Remove a profile and its persisted credentials.                        |
| `profiles.deleteById(String id)`               | ⛔     | Escape hatch for delete.                                               |
| `profiles.newEmpty()`                          | ⛔     | Create an empty slot for the next `up()` with a fresh authkey.          |

```dart
final all = await tsnet.profiles.list();
final work = all.firstWhere((p) => p.tailnetName == 'acme.com');
await tsnet.profiles.switchTo(work);
```

## `prefs`

Node preferences — subnet routes, shields, tags, auto-update. The long
tail of tsnet config that doesn't warrant its own namespace.

| API                                                | Status | Purpose                                                           |
| -------------------------------------------------- | ------ | ----------------------------------------------------------------- |
| `prefs.get()` → `TailscalePrefs`                   | ⛔     | Current prefs snapshot.                                            |
| `prefs.setAdvertisedRoutes(List<String> cidrs)`    | ⛔     | Replace the set of advertised subnet routes.                        |
| `prefs.setAcceptRoutes(bool)`                      | ⛔     | Accept subnet routes advertised by other nodes.                     |
| `prefs.setShieldsUp(bool)`                         | ⛔     | Block all inbound connections.                                      |
| `prefs.setAutoUpdate(bool)`                        | ⛔     | Opt in/out of automatic tsnet updates.                              |
| `prefs.setAdvertisedTags(List<String> tags)`       | ⛔     | Replace the set of ACL tags this node advertises.                   |
| `prefs.updateMasked(PrefsUpdate)`                  | ⛔     | Atomic multi-field edit.                                            |

```dart
await tsnet.prefs.setShieldsUp(true);

await tsnet.prefs.updateMasked(PrefsUpdate(
  advertisedRoutes: ['10.0.0.0/24'],
  acceptRoutes: true,
));
```

## `diag`

Observability and diagnostics. Read-only; nothing here affects
connectivity.

| API                                                              | Status | Purpose                                                            |
| ---------------------------------------------------------------- | ------ | ------------------------------------------------------------------ |
| `diag.ping(ip, {timeout, type})` → `PingResult`                  | ⛔     | Round-trip + direct-vs-DERP diagnostic.                             |
| `diag.metrics()` → `String`                                      | ⛔     | Prometheus-format metrics snapshot from the embedded runtime.       |
| `diag.derpMap()` → `DERPMap`                                     | ⛔     | Current DERP relay map.                                             |
| `diag.checkUpdate()` → `ClientVersion?`                          | ⛔     | Latest tsnet version if newer than embedded, else null.             |

```dart
final ping = await tsnet.diag.ping('100.64.0.5');
print('RTT: ${ping.latency}, via: ${ping.direct ? "direct" : ping.derpRegion}');
```

## `whois` (top-level)

Resolve a tailnet IP to peer identity. Kept flat on `Tailscale` rather
than in a namespace because it's a single cross-cutting utility.

| API                                                | Status | Purpose                                                              |
| -------------------------------------------------- | ------ | -------------------------------------------------------------------- |
| `whois(ip)` → `PeerIdentity?`                      | ⛔     | Identity lookup by tailnet IP. Null if not known on this tailnet.     |

```dart
final server = await tsnet.tcp.bind(8080);
await for (final conn in server) {
  final identity = await tsnet.whois(conn.remoteAddress.address);
  if (identity == null || !identity.tags.contains('tag:trusted')) {
    await conn.close();
    continue;
  }
  handle(conn);
}
```

## Errors

Structured exception taxonomy. Every operation-specific failure is an
`Exception` subtype carrying an optional `TailscaleErrorCode` and HTTP
`statusCode`.

| Type                                    | Thrown by                                     |
| --------------------------------------- | --------------------------------------------- |
| `TailscaleUsageException`               | Misuse (e.g. `http.client` before `up`).       |
| `TailscaleUpException`                  | `up()` failed before reaching a stable state. |
| `TailscaleListenException`              | `http.expose` (reverse-proxy).                 |
| `TailscaleStatusException`              | `status()`.                                    |
| `TailscaleLogoutException`              | `logout()`.                                    |
| `TailscaleTaildropException`            | `taildrop.*`.                                  |
| `TailscaleServeException`               | `serve.*` (incl. ETag conflicts).               |
| `TailscalePrefsException`               | `prefs.*`.                                      |
| `TailscaleProfilesException`            | `profiles.*`.                                   |
| `TailscaleExitNodeException`            | `exitNode.*`.                                   |
| `TailscaleDiagException`                | `diag.*`.                                       |
| `TailscaleRuntimeError` (not an Exception) | Async errors pushed from Go via `onError`. |

```dart
try {
  await tsnet.serve.setConfig(updated);
} on TailscaleServeException catch (e) {
  switch (e.code) {
    case TailscaleErrorCode.conflict:       // retry
    case TailscaleErrorCode.forbidden:      // ACL
    case TailscaleErrorCode.featureDisabled: // Serve off
    default: rethrow;
  }
}
```
