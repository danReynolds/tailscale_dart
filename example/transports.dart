/// Combined TCP + TLS + UDP demo exercising every Phase 3 / 5
/// transport primitive. Two Dart processes against the same
/// tailnet: one runs as server, the other as client; they exchange
/// a payload over the chosen transport.
///
/// Usage:
///
///   # Terminal 1 — server
///   export TSNET_AUTHKEY=tskey-auth-...
///   dart run example/transports.dart server `<tcp|tls|udp>`
///
///   # Terminal 2 — client (passes server's tailnet IP)
///   export TSNET_AUTHKEY=tskey-auth-...
///   dart run example/transports.dart client `<tcp|tls|udp>` `<peerIp>`
///
/// Notes:
/// - `tls` requires a real Tailscale tailnet with HTTPS + MagicDNS
///   enabled (Headscale doesn't provision certs). Pass the server's
///   MagicDNS name (e.g. `server-node.tailnet.ts.net`) as the peer
///   argument, not a raw tailnet IP — the cert SAN is the FQDN.
/// - `udp` binds on the server's primary tailnet IPv4; the client
///   sends one datagram and awaits an echo.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/tailscale.dart';

const _port = 7100;
const _payload = 'hello from tailnet';

enum _Transport { tcp, tls, udp }

Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      !(args[0] == 'server' || args[0] == 'client') ||
      !_Transport.values.any((t) => t.name == args[1])) {
    stderr.writeln('Usage: dart run example/transports.dart '
        '<server|client> <tcp|tls|udp> [peerIp]');
    exit(64);
  }
  final role = args[0];
  final transport = _Transport.values.firstWhere((t) => t.name == args[1]);

  final authKey = Platform.environment['TSNET_AUTHKEY'];
  if (authKey == null || authKey.isEmpty) {
    stderr.writeln('Set TSNET_AUTHKEY to a Tailscale pre-auth key.');
    exit(64);
  }

  final stateDir = '${Directory.systemTemp.path}/ts-transports-$role-${transport.name}';
  Directory(stateDir).createSync(recursive: true);
  Tailscale.init(stateDir: stateDir, logLevel: TailscaleLogLevel.error);
  final tsnet = Tailscale.instance;

  final status = await tsnet.up(
    hostname: 'transports-$role-${transport.name}',
    authKey: authKey,
  );
  if (!status.isRunning) {
    stderr.writeln('Node did not reach running: ${status.state}');
    exit(1);
  }
  stderr.writeln('Connected. Tailnet IPs: ${status.tailscaleIPs}');

  if (role == 'server') {
    await _server(tsnet, transport, status);
  } else {
    if (args.length < 3) {
      stderr.writeln('Client mode needs the server\'s tailnet IP (or MagicDNS name for tls).');
      exit(64);
    }
    await _client(tsnet, transport, args[2]);
    await tsnet.down();
  }
}

Future<void> _server(
  Tailscale tsnet,
  _Transport transport,
  TailscaleStatus status,
) async {
  ProcessSignal.sigint.watch().listen((_) async {
    stderr.writeln('\nShutting down.');
    await tsnet.down();
    exit(0);
  });

  switch (transport) {
    case _Transport.tcp:
      final server = await tsnet.tcp.bind(_port);
      stderr.writeln('TCP listening on tailnet:$_port');
      server.listen(_echoSocket);
    case _Transport.tls:
      final domains = await tsnet.tls.domains();
      if (domains.isEmpty) {
        stderr.writeln('tls.domains() is empty — enable HTTPS + MagicDNS on '
            'the tailnet admin panel.');
        exit(1);
      }
      final server = await tsnet.tls.bind(_port);
      stderr.writeln('TLS listening on $domains:$_port');
      server.listen(_echoSocket);
    case _Transport.udp:
      final host = status.ipv4;
      if (host == null) {
        stderr.writeln('Node has no tailnet IPv4; cannot bind UDP.');
        exit(1);
      }
      final sock = await tsnet.udp.bind(host, _port);
      stderr.writeln('UDP listening on $host:$_port');
      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        stderr.writeln('UDP datagram from ${dg.address.address}:${dg.port} '
            '(${dg.data.length} bytes)');
        sock.send(dg.data, dg.address, dg.port);
      });
  }
}

Future<void> _client(
  Tailscale tsnet,
  _Transport transport,
  String peer,
) async {
  switch (transport) {
    case _Transport.tcp:
      final socket = await tsnet.tcp.dial(peer, _port);
      await _sendAndPrintEcho(socket);
    case _Transport.tls:
      // Route the underlying TCP through the embedded tsnet node,
      // then layer TLS on top in Dart. SecureSocket.secure() accepts
      // the existing Socket and performs the handshake against the
      // server's Let's Encrypt cert (served by the peer's tsnet
      // ListenTLS). Using SecureSocket.connect() directly would
      // bypass tsnet and rely on the host OS network stack — wrong
      // transport, would only work if the host also has Tailscale
      // installed and MagicDNS resolved.
      //
      // `peer` must be the node's MagicDNS name (not a raw tailnet
      // IP) because the cert's SAN is the MagicDNS FQDN.
      final raw = await tsnet.tcp.dial(peer, _port);
      final socket = await SecureSocket.secure(raw, host: peer);
      await _sendAndPrintEcho(socket);
    case _Transport.udp:
      final bound = await tsnet.udp.bind(
        (await tsnet.status()).ipv4!,
        0,
      );
      final done = _receiveOneDatagram(bound);
      bound.send(
        utf8.encode(_payload),
        InternetAddress(peer),
        _port,
      );
      stderr.writeln('UDP sent ${_payload.length} bytes');
      final dg = await done;
      stdout.writeln('Echoed: ${utf8.decode(dg.data)}');
      bound.close();
  }
}

void _echoSocket(Socket socket) {
  stderr.writeln('Accepted ${socket.remoteAddress.address}');
  socket.listen(
    socket.add,
    onDone: () => socket.close(),
    onError: (_) => socket.close(),
    cancelOnError: true,
  );
}

Future<void> _sendAndPrintEcho(Socket socket) async {
  try {
    final bytes = Uint8List.fromList(utf8.encode(_payload));
    socket.add(bytes);
    await socket.flush();
    stderr.writeln('Sent ${bytes.length} bytes');

    var received = 0;
    await for (final chunk in socket) {
      stdout.write(utf8.decode(chunk, allowMalformed: true));
      received += chunk.length;
      if (received >= bytes.length) break;
    }
    stdout.writeln();
  } finally {
    await socket.close();
  }
}

Future<Datagram> _receiveOneDatagram(RawDatagramSocket sock) async {
  final done = await sock
      .firstWhere((e) => e == RawSocketEvent.read)
      .timeout(const Duration(seconds: 10));
  // Silence unused-variable warning from `done`; the event has fired.
  assert(done == RawSocketEvent.read);
  final dg = sock.receive();
  if (dg == null) {
    throw StateError('read event fired but no datagram available');
  }
  return dg;
}
