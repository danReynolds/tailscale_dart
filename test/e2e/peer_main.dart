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
///   CONTROL_URL     — Headscale URL; omit for Tailscale's default control
///                     plane
///   AUTH_KEY        — reusable preauth key (optional; omit to reconnect with
///                     previously persisted credentials in STATE_DIR)
///   EPHEMERAL       — `1`/`true` to register as a short-lived node
///   HOSTNAME        — tailnet-visible hostname (default: dune-e2e-peer)
///   ADVERTISED_ROUTES — optional comma-separated routes to advertise through
///                     prefs before READY, e.g. `0.0.0.0/0,::/0`.
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
  final controlUrl = Platform.environment['CONTROL_URL'];
  final authKey = Platform.environment['AUTH_KEY'] ?? '';
  final ephemeral = _optionalBoolEnv('EPHEMERAL');
  final hostname = Platform.environment['HOSTNAME'] ?? 'dune-e2e-peer';
  final advertisedRoutes = _optionalCsvEnv('ADVERTISED_ROUTES');
  final responseBody =
      Platform.environment['RESPONSE_BODY'] ?? 'hello from peer';

  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  final running = tsnet.onStateChange.firstWhere((s) => s == NodeState.running);

  await tsnet.up(
    hostname: hostname,
    authKey: authKey.isEmpty ? null : authKey,
    ephemeral: ephemeral,
    controlUrl: controlUrl == null || controlUrl.isEmpty
        ? null
        : Uri.parse(controlUrl),
  );
  await running.timeout(const Duration(seconds: 60));

  if (advertisedRoutes.isNotEmpty) {
    await tsnet.prefs.setAdvertisedRoutes(advertisedRoutes);
  }

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

  // Process newline commands from the parent until stdin closes. Commands:
  //   DIAL <host> <port>          — open an outbound TCP connection to the
  //                                 parent's listener, so the parent can assert
  //                                 the identity attached to the accepted conn.
  //   HTTPGET <host> <port> <path> — issue an inbound HTTP GET to the parent's
  //                                 http.bind server, so the parent can assert
  //                                 the identity attached to the request.
  // Closing stdin ends the loop and triggers shutdown.
  final commands = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  await for (final line in commands) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) continue;
    switch (parts[0]) {
      case 'DIAL' when parts.length == 3:
        final host = parts[1];
        final port = int.tryParse(parts[2]);
        if (port == null) continue;
        try {
          final conn = await tsnet.tcp.dial(
            host,
            port,
            timeout: const Duration(seconds: 15),
          );
          await conn.output.write(utf8.encode('hello-from-peer'));
          await conn.output.close();
          // Give the parent time to accept and read before tearing down.
          await conn.done.timeout(const Duration(seconds: 5), onTimeout: () {});
          await conn.close();
        } catch (e) {
          stderr.writeln('peer: DIAL $host:$port failed: $e');
        }
      case 'HTTPGET' when parts.length == 4:
        final host = parts[1];
        final port = int.tryParse(parts[2]);
        final path = parts[3];
        if (port == null) continue;
        try {
          final resp = await tsnet.http.client
              .get(Uri.parse('http://$host:$port$path'))
              .timeout(const Duration(seconds: 15));
          stderr.writeln('peer: HTTPGET $host:$port$path -> ${resp.statusCode}');
        } catch (e) {
          stderr.writeln('peer: HTTPGET $host:$port$path failed: $e');
        }
    }
  }

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

List<String> _optionalCsvEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) return const [];
  return [
    for (final item in value.split(','))
      if (item.trim().isNotEmpty) item.trim(),
  ];
}

bool _optionalBoolEnv(String name) {
  final raw = Platform.environment[name]?.trim().toLowerCase();
  return raw == '1' || raw == 'true' || raw == 'yes';
}
