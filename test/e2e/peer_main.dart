/// Peer node for multi-node E2E tests.
///
/// Spawned as a subprocess by [test/e2e/e2e_test.dart]. Brings up an embedded
/// Tailscale node, exposes:
///   - a trivial tailnet HTTP server on port 80 (via `http.bind`), and
///   - a raw TCP byte-echo server on tailnet port 7000 (via `tcp.bind`),
///   - a UDP datagram echo binding on tailnet port 7001 (via `udp.bind`),
/// prints `READY <ipv4>` on stdout once the node is Running, then shuts down
/// cleanly when stdin closes.
///
/// Configured via environment variables:
///   STATE_DIR       — directory the peer owns for its Tailscale state
///   CONTROL_URL     — Headscale URL
///   AUTH_KEY        — reusable preauth key (optional; omit to reconnect with
///                     previously persisted credentials in STATE_DIR)
///   HOSTNAME        — tailnet-visible hostname (default: dune-e2e-peer)
///   RESPONSE_BODY   — body returned by the tailnet HTTP server for GET
///                     (default: 'hello from peer'). POST requests echo the
///                     request body as `echo: <body>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<void> main(List<String> args) async {
  // Warmup mode: triggered by the test's setUpAll to populate the package's
  // native-asset cache before the parent process loads the .so. Exit
  // immediately — we just want the build hook to have run.
  if (Platform.environment['PEER_WARMUP'] == '1') {
    return;
  }

  final stateDir = _requiredEnv('STATE_DIR');
  final controlUrl = _requiredEnv('CONTROL_URL');
  final authKey = Platform.environment['AUTH_KEY'] ?? '';
  final hostname = Platform.environment['HOSTNAME'] ?? 'dune-e2e-peer';
  final responseBody =
      Platform.environment['RESPONSE_BODY'] ?? 'hello from peer';

  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  final running = tsnet.onStateChange.firstWhere((s) => s == NodeState.running);

  await tsnet.up(
    hostname: hostname,
    authKey: authKey.isEmpty ? null : authKey,
    controlUrl: Uri.parse(controlUrl),
  );
  await running.timeout(const Duration(seconds: 60));
  final httpServer = await tsnet.http.bind(port: 80);
  httpServer.requests.listen((req) async {
    if (req.method == 'POST') {
      final body = await utf8.decoder.bind(req.body).join();
      await req.respond(
        headers: {'content-type': 'text/plain'},
        body: 'echo: $body',
      );
    } else {
      await req.respond(
        headers: {'content-type': 'text/plain'},
        body: responseBody,
      );
    }
  });

  final status = await tsnet.status();
  final ipv4 = status.ipv4;
  if (ipv4 == null) {
    stderr.writeln('peer: up() completed but no IPv4 was assigned');
    exitCode = 2;
    return;
  }

  // Raw TCP byte-echo server on tailnet:7000.
  final echoServer = await tsnet.tcp.bind(port: 7000);
  echoServer.connections.listen((conn) {
    unawaited(
      conn.output
          .writeAll(conn.input, close: true)
          .catchError((_) => conn.abort()),
    );
  });

  // UDP datagram echo binding on tailnet:7001.
  final udpEcho = await tsnet.udp.bind(address: ipv4, port: 7001);
  udpEcho.datagrams.listen((datagram) {
    unawaited(udpEcho.send(datagram.payload, to: datagram.remote));
  });

  // Leading newline: the Dart build hook writes `Running build hooks...`
  // without a trailing newline, so force a line break before our sentinel.
  stdout.write('\nREADY $ipv4\n');
  await stdout.flush();

  // Shut down when the parent closes stdin.
  await stdin.drain<void>();

  try {
    await udpEcho.close();
  } catch (_) {}
  try {
    await echoServer.close();
  } catch (_) {}
  try {
    await httpServer.close();
  } catch (_) {}
  try {
    await tsnet.down();
  } catch (_) {}
}

String _requiredEnv(String name) {
  final v = Platform.environment[name];
  if (v == null || v.isEmpty) {
    stderr.writeln('peer: missing required env var $name');
    exit(2);
  }
  return v;
}
