/// Raw TCP echo demo — one Dart process binds a tailnet port and
/// echoes bytes, another dials it and exchanges a payload.
///
/// Usage: run two instances against the same tailnet.
///
///   # Terminal 1 — echo server
///   export TSNET_AUTHKEY=tskey-auth-...
///   dart run example/tcp_echo.dart server
///
///   # Terminal 2 — client (pass the server's tailnet IP)
///   export TSNET_AUTHKEY=tskey-auth-...
///   dart run example/tcp_echo.dart client 100.64.0.5
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/tailscale.dart';

const _tailnetPort = 7000;

Future<void> main(List<String> args) async {
  if (args.isEmpty || (args[0] != 'server' && args[0] != 'client')) {
    stderr.writeln(
      'Usage: dart run example/tcp_echo.dart <server|client> [nodeIp]',
    );
    exit(64);
  }

  final stateDir = '${Directory.systemTemp.path}/tailscale-tcp-echo-${args[0]}';
  Directory(stateDir).createSync(recursive: true);

  final authKey = Platform.environment['TSNET_AUTHKEY'];
  if (authKey == null || authKey.isEmpty) {
    stderr.writeln('Set TSNET_AUTHKEY to a Tailscale pre-auth key.');
    exit(64);
  }

  Tailscale.init(stateDir: stateDir, logLevel: TailscaleLogLevel.error);
  final tsnet = Tailscale.instance;

  final status = await tsnet.up(
    hostname: 'tcp-echo-${args[0]}',
    authKey: authKey,
  );
  if (!status.isRunning) {
    stderr.writeln('Node did not reach running state: ${status.state}');
    exit(1);
  }
  stderr.writeln('Connected. Tailnet IP: ${status.ipv4}');

  if (args[0] == 'server') {
    await _runServer(tsnet);
  } else {
    if (args.length < 2) {
      stderr.writeln('Client mode needs the server\'s tailnet IP.');
      exit(64);
    }
    await _runClient(tsnet, args[1]);
    await tsnet.down();
  }
}

Future<void> _runServer(Tailscale tsnet) async {
  final server = await tsnet.tcp.bind(port: _tailnetPort);
  stderr.writeln('Listening on tailnet:$_tailnetPort');

  // Ctrl-C cleanly closes the bind (so Go tears down the tailnet listener).
  ProcessSignal.sigint.watch().listen((_) async {
    stderr.writeln('\nShutting down.');
    await server.close();
    await tsnet.down();
    exit(0);
  });

  server.connections.listen((conn) {
    stderr.writeln('Accepted ${conn.remote}');
    unawaited(
      conn.output
          .writeAll(conn.input, close: true)
          .catchError((_) => conn.abort()),
    );
  });
}

Future<void> _runClient(Tailscale tsnet, String nodeIp) async {
  final conn = await tsnet.tcp.dial(nodeIp, _tailnetPort);
  try {
    final payload = Uint8List.fromList(utf8.encode('hello over tcp!'));
    await conn.output.write(payload);
    await conn.output.close();
    stderr.writeln('Sent ${payload.length} bytes');

    var received = 0;
    await for (final chunk in conn.input) {
      stdout.write(utf8.decode(chunk, allowMalformed: true));
      received += chunk.length;
      if (received >= payload.length) break;
    }
    stdout.writeln();
  } finally {
    await conn.close();
  }
}
