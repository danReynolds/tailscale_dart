# Current Architecture and API Feedback Draft

## Status

This is the current v1 direction after replacing the earlier authenticated
loopback session design with fd-backed local capabilities.

The implementation is no longer a throwaway spike. HTTP, TCP, and UDP are
implemented and validated through unit tests, package tests, Flutter demo tests,
and Headscale E2E. It is still pre-production/beta until the remaining
hardening work is complete.

## Summary

`package:tailscale` embeds a Go `tsnet.Server` inside a Dart or Flutter process.
The app becomes its own tailnet node.

Go owns:

- Tailscale control-plane login and node state
- WireGuard/magicsock/tailnet routing
- ACL enforcement
- peer/node identity from Tailscale
- tailnet TCP, UDP, and HTTP establishment

Dart owns:

- public package API
- app-facing lifecycle
- byte-stream consumption and production
- HTTP request handling
- demo/UI/application code

The core architecture is:

```text
Dart app
  |
  | control calls over FFI
  v
Go tsnet runtime
  |
  | tailnet traffic
  v
Other Tailscale nodes

Data plane on POSIX:
Go-owned tailnet conn/listener/request
  -> private socketpair/fd capability
  -> Dart package-native transport object
```

The fd is the local authority boundary. On POSIX, possession of the fd is the
capability to read/write that one connection or datagram binding. This removes
the need for the old loopback carrier, session handshake, per-frame MAC,
stream multiplexer, and replay-cache machinery on POSIX.

## Design Principles

- Do not pretend these are `dart:io.Socket` objects.
- Keep HTTP, TCP, and UDP semantics separate.
- Let Go own tailnet establishment and metadata authority.
- Let Dart expose clean package-native APIs.
- Use fd handoff where the OS gives us a private local capability.
- Windows is not supported in v1.

## Backend Model

### Control Plane

Control operations remain request/response FFI calls through a worker isolate:

- `up`
- `down`
- `logout`
- `status`
- `nodes`
- `whois`
- diagnostics
- listener/binding setup and teardown

These are not high-volume data paths.

### TCP

For outbound TCP:

1. Dart calls `tcp.dial(host, port)`.
2. Go calls `tsnet.Server.Dial`.
3. Go creates a socketpair.
4. Go pipes the tailnet connection to one end.
5. Dart adopts the other fd as a `TailscaleConnection`.

For inbound TCP:

1. Dart calls `tcp.bind(port: port)`.
2. Go owns the `tsnet.Server.Listen("tcp", ...)` listener.
3. Dart starts a background accept isolate.
4. Each accepted tailnet connection is handed to Dart as a new fd-backed
   `TailscaleConnection`.

### UDP

UDP is message-preserving, not stream-shaped.

Go owns the tailnet packet connection through `tsnet.Server.ListenPacket`.
Dart gets a private fd-backed datagram binding. Each received datagram carries:

- remote endpoint
- payload
- optional identity metadata

Payloads over 60 KiB are rejected rather than fragmented.

### HTTP

HTTP is package-native, not a local reverse proxy.

Outbound HTTP:

- callers use `Tailscale.http.client`
- the public type is still `package:http.Client`
- Go uses `tsnet.Server.HTTPClient()`
- request and response bodies stream over private fd-backed channels

Inbound HTTP:

- callers use `Tailscale.http.bind(port: ...)`
- Go owns the tailnet HTTP listener and parser
- each request is exposed as a `TailscaleHttpRequest`
- request body and response body are fd-backed streams
- there is no `localPort` in v1

## Example Use Cases

The intended v1 use cases are deliberately narrow and private-tailnet oriented:

- A Flutter app joins a tailnet and calls private HTTP APIs on other nodes.
- A Flutter or Dart app exposes an in-process private HTTP admin/debug endpoint
  to other tailnet nodes.
- A mobile app and desktop app exchange raw TCP bytes for a custom protocol
  without installing a system VPN.
- A game, collaboration tool, or local-first app sends UDP datagrams between
  tailnet nodes while preserving message boundaries.
- A validation or diagnostics app lists nodes, pings peers, runs `whois`, and
  probes HTTP/TCP/UDP reachability.
- A Shelf-based Dart backend runs inside an app process and is reachable only
  over the tailnet.

## Public API Examples

### Start A Node

```dart
import 'package:tailscale/tailscale.dart';

Future<Tailscale> startNode() async {
  Tailscale.init(
    stateDir: '/path/to/app/state',
    logLevel: TailscaleLogLevel.info,
  );

  final ts = Tailscale.instance;

  final status = await ts.up(
    hostname: 'my-dart-node',
    authKey: 'tskey-auth-...',
    // For Headscale:
    // controlUrl: Uri.parse('http://127.0.0.1:8080'),
  );

  print('Running as ${status.ipv4}');
  return ts;
}
```

### Discover Nodes

```dart
final ts = await startNode();

final nodes = await ts.nodes();
final onlineNodes = nodes.where((node) => node.online).toList();

for (final node in onlineNodes) {
  print('${node.hostName}: ${node.ipv4}');
}

final byIp = await ts.nodeByIp('100.64.0.2');
print(byIp?.hostName);
```

### HTTP Client

```dart
final ts = await startNode();

final response = await ts.http.client.get(
  Uri.parse('http://100.64.0.2:8080/demo'),
);

print(response.statusCode);
print(response.body);
```

### HTTP Server

```dart
import 'dart:convert';

final ts = await startNode();

final server = await ts.http.bind(port: 8080);
print('HTTP listening on ${server.tailnet}');

server.requests.listen((request) async {
  if (request.method == 'POST' && request.uri.path == '/echo') {
    final body = await utf8.decoder.bind(request.body).join();
    await request.respond(
      headers: {'content-type': 'text/plain'},
      body: 'echo: $body',
    );
    return;
  }

  await request.respond(
    headers: {'content-type': 'text/plain'},
    body: 'hello from ${server.tailnet}',
  );
});

// Later:
await server.close();
```

### Shelf Adapter Example

Shelf can be layered as an adapter over `TailscaleHttpServer.requests`.
This avoids `shelf_io.serve`, because there is no `dart:io` server socket.

```dart
import 'dart:async';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:tailscale/tailscale.dart';

Future<TailscaleHttpServer> bindShelf({
  required Tailscale tailscale,
  required int port,
  required shelf.Handler handler,
}) async {
  final server = await tailscale.http.bind(port: port);

  server.requests.listen((request) async {
    try {
      final shelfRequest = shelf.Request(
        request.method,
        _requestedUri(request),
        protocolVersion: _protocolVersion(request.protocolVersion),
        headers: {
          for (final entry in request.headersAll.entries)
            entry.key: entry.value.length == 1
                ? entry.value.single
                : entry.value,
        },
        body: request.body,
        context: {
          'tailscale.local': request.local,
          'tailscale.remote': request.remote,
          'tailscale.request': request,
        },
      );

      final shelfResponse = await handler(shelfRequest);

      request.response.statusCode = shelfResponse.statusCode;
      for (final entry in shelfResponse.headers.entries) {
        final value = entry.value;
        if (value is Iterable) {
          for (final item in value) {
            request.response.addHeader(entry.key, item.toString());
          }
        } else {
          request.response.setHeader(entry.key, value.toString());
        }
      }
      await request.response.writeAll(shelfResponse.read());
      await request.response.close();
    } catch (_) {
      await request.respond(
        statusCode: 500,
        headers: {'content-type': 'text/plain'},
        body: 'Internal Server Error',
      );
    }
  });

  return server;
}

Uri _requestedUri(TailscaleHttpRequest request) {
  final path = request.requestUri.startsWith('/')
      ? request.requestUri
      : '/${request.requestUri}';
  final host = request.host.isEmpty ? request.local.toString() : request.host;
  return Uri.parse('http://$host$path');
}

String _protocolVersion(String proto) =>
    proto.startsWith('HTTP/') ? proto.substring(5) : proto;
```

Example Shelf app:

```dart
final ts = await startNode();

final router = Router()
  ..get('/health', (shelf.Request request) {
    return shelf.Response.ok('ok');
  })
  ..post('/echo', (shelf.Request request) async {
    final body = await request.readAsString();
    return shelf.Response.ok(
      'echo: $body',
      headers: {'content-type': 'text/plain'},
    );
  });

final handler = const shelf.Pipeline()
    .addMiddleware(shelf.logRequests())
    .addHandler(router.call);

final server = await bindShelf(tailscale: ts, port: 8080, handler: handler);

print('Shelf app listening on ${server.tailnet}');
```

Current limitation: hijacking/WebSocket upgrade is not part of v1.
Normal request/response Shelf handlers map cleanly.

### TCP Server

```dart
final ts = await startNode();

final listener = await ts.tcp.bind(port: 7000);
print('TCP listening on ${listener.local}');

listener.connections.listen((conn) {
  print('TCP connection from ${conn.remote}');
  unawaited(
    conn.output
        .writeAll(conn.input, close: true)
        .catchError((_) => conn.abort()),
  );
});

// Later:
await listener.close();
```

### TCP Client

```dart
import 'dart:convert';

final ts = await startNode();

final conn = await ts.tcp.dial(
  '100.64.0.2',
  7000,
  timeout: const Duration(seconds: 5),
);

try {
  await conn.output.write(utf8.encode('hello tcp'));
  await conn.output.close();

  final response = await utf8.decoder.bind(conn.input).join();
  print(response);
} finally {
  await conn.close();
}
```

### UDP Echo Binding

```dart
final ts = await startNode();

final udp = await ts.udp.bind(port: 7001);

print('UDP listening on ${udp.local}');

udp.datagrams.listen((datagram) async {
  await udp.send(datagram.payload, to: datagram.remote);
});

// Later:
await udp.close();
```

### UDP Client

```dart
import 'dart:convert';

final ts = await startNode();

final udp = await ts.udp.bind(port: 0);

final firstReply = udp.datagrams.first;

await udp.send(
  utf8.encode('hello udp'),
  to: const TailscaleEndpoint(address: '100.64.0.2', port: 7001),
);

final reply = await firstReply.timeout(const Duration(seconds: 5));
print('reply from ${reply.remote}: ${utf8.decode(reply.payload)}');

await udp.close();
```

## Lifecycle and Shutdown

The package intentionally does not expose `dart:io.Socket`. TCP is modeled as a
full-duplex tailnet byte stream with explicit read and write halves:

- `connection.input` is a single-subscription stream of received bytes.
- `connection.output.write(...)` completes when bytes are accepted locally.
- `connection.output.close()` half-closes the local write side and lets the app
  keep reading.
- `connection.close()` means the app is done with the whole connection.
- `connection.abort()` is immediate teardown.

HTTP request bodies are single-subscription streams for the same reason Shelf
and `dart:io` request bodies are: the body is a live stream, not a replayable
buffer. Handlers that need multiple consumers should buffer explicitly.

UDP bindings are message-oriented. Received datagrams preserve boundaries, but
UDP has no delivery or backpressure guarantee; datagrams may be dropped while no
listener is attached or while the subscription is paused.

Windows is not supported in v1.

## Validation So Far

Automated validation currently includes:

- Go unit tests
- Dart root tests
- Dart static analysis
- demo core tests
- Flutter demo tests
- Headscale E2E with two nodes

Manual validation has passed on:

- macOS
- iOS
- Android

The validated probe surface includes:

- node startup and login
- node listing
- `whois`
- ping
- HTTP GET
- HTTP POST
- TCP echo
- UDP echo

## Current Maturity

This is beta/pre-production.

It is production-shaped in architecture, but not yet production-hardened.

Known remaining work:

- Linux real-tailnet validation.
- Windows support decision.
- More HTTP fd server lifecycle/error tests.
- More stress tests for backpressure and resource limits.
- Clear docs around unsupported platforms and shutdown semantics.
- Decide whether a Shelf adapter should be public API or documentation-only.
- Decide whether WebSocket/hijack support belongs in v1, later, or never.

## Feedback Questions

1. Is the fd-as-local-capability model the right v1 foundation for POSIX?
2. Is the decision not to expose `dart:io.Socket` acceptable, or will users
   strongly expect socket compatibility?
3. Does the HTTP API feel right as package-native request/response objects?
4. Should Shelf support be a first-class helper, or just a documented adapter?
5. Are TCP close/abort and UDP drop semantics clear enough for users?
6. Is Windows acceptable as a separate backend/follow-up, or does v1 need a
   unified cross-platform raw transport story?
7. Are there missing production constraints around memory caps, accept backlog,
   request body streaming, or cancellation?
