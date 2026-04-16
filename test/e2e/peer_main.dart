/// Peer node for multi-node E2E tests.
///
/// Spawned as a subprocess by [test/e2e/e2e_test.dart]. Brings up an embedded
/// Tailscale node, exposes a trivial local HTTP server on the tailnet via
/// [Tailscale.listen], prints `READY <ipv4>` on stdout once the node is
/// Running, then shuts down cleanly when stdin closes.
///
/// Configured via environment variables:
///   STATE_DIR       — directory the peer owns for its Tailscale state
///   CONTROL_URL     — Headscale URL
///   AUTH_KEY        — reusable preauth key (optional; omit to reconnect with
///                     previously persisted credentials in STATE_DIR)
///   HOSTNAME        — tailnet-visible hostname (default: dune-e2e-peer)
///   RESPONSE_BODY   — body returned by the local HTTP server for GET
///                     (default: 'hello from peer'). POST requests echo the
///                     request body as `echo: <body>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<void> main(List<String> args) async {
  final stateDir = _requiredEnv('STATE_DIR');
  final controlUrl = _requiredEnv('CONTROL_URL');
  final authKey = Platform.environment['AUTH_KEY'] ?? '';
  final hostname = Platform.environment['HOSTNAME'] ?? 'dune-e2e-peer';
  final responseBody =
      Platform.environment['RESPONSE_BODY'] ?? 'hello from peer';

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.text;
    if (req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      req.response.write('echo: $body');
    } else {
      req.response.write(responseBody);
    }
    await req.response.close();
  });

  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  final running =
      tsnet.onStateChange.firstWhere((s) => s == NodeState.running);

  await tsnet.up(
    hostname: hostname,
    authKey: authKey.isEmpty ? null : authKey,
    controlUrl: Uri.parse(controlUrl),
  );
  await running.timeout(const Duration(seconds: 60));
  await tsnet.listen(server.port, tailnetPort: 80);

  final status = await tsnet.status();
  final ipv4 = status.ipv4;
  if (ipv4 == null) {
    stderr.writeln('peer: up() completed but no IPv4 was assigned');
    exitCode = 2;
    return;
  }

  // Leading newline: the Dart build hook writes `Running build hooks...`
  // without a trailing newline, so force a line break before our sentinel.
  stdout.write('\nREADY $ipv4\n');
  await stdout.flush();

  // Shut down when the parent closes stdin.
  await stdin.drain<void>();

  try {
    await tsnet.down();
  } catch (_) {}
  await server.close(force: true);
}

String _requiredEnv(String name) {
  final v = Platform.environment[name];
  if (v == null || v.isEmpty) {
    stderr.writeln('peer: missing required env var $name');
    exit(2);
  }
  return v;
}
