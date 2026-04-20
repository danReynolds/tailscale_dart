import 'dart:io';

import 'package:meta/meta.dart';

import '../errors.dart';

/// Raw TCP primitives between tailnet peers — peer-to-peer connections
/// tunneled over WireGuard, no TLS, no HTTP framing.
///
/// Traffic flows directly between nodes when a peer-to-peer path is
/// available, falling back to a DERP relay otherwise; both cases are
/// transparent to the caller. See
/// <https://tailscale.com/kb/1257/connection-types>.
///
/// Verb split: [dial] for outbound connections matches Go / tsnet
/// (`Server.Dial`); [bind] for inbound listeners matches `dart:io`
/// (`ServerSocket.bind`). Using `listen` for the factory would collide
/// with `ServerSocket.listen(callback)` — the Dart stream subscription
/// that's the idiomatic accept loop.
class Tcp {
  /// Library-internal. Reach via `Tailscale.instance.tcp`.
  @internal
  Tcp.internal({
    required Future<({int loopbackPort, String token})> Function(
      String host,
      int port,
      Duration? timeout,
    ) dialFn,
  }) : _dialFn = dialFn;

  final Future<({int loopbackPort, String token})> Function(
    String host,
    int port,
    Duration? timeout,
  ) _dialFn;

  /// Opens a TCP connection to a peer on the tailnet. Mirrors
  /// `tsnet.Server.Dial`.
  ///
  /// [host] may be a tailnet IP (e.g. `100.64.0.5`) or a
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) name
  /// (e.g. `my-peer` or `my-peer.tailnet.ts.net`). [timeout] applies
  /// to the tailnet dial and the loopback handshake only — not to
  /// the lifetime of the returned socket.
  ///
  /// Implemented as a one-shot loopback bridge: the embedded Go
  /// runtime opens the tailnet conn and pipes bytes through a
  /// per-call 127.0.0.1 listener. A random per-call token is written
  /// as the first bytes on the wire so co-resident processes can't
  /// hijack the bridge.
  ///
  /// Throws [TailscaleTcpException] on tailnet-side failures (no
  /// route, connection refused, etc.) or if the loopback bridge
  /// handshake fails.
  Future<Socket> dial(String host, int port, {Duration? timeout}) async {
    final (:loopbackPort, :token) = await _dialFn(host, port, timeout);

    late Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        loopbackPort,
        timeout: timeout,
      );
    } catch (e) {
      throw TailscaleTcpException(
        'Failed to connect to loopback bridge on port $loopbackPort',
        cause: e,
      );
    }

    try {
      socket.add(token.codeUnits);
      await socket.flush();
    } catch (e) {
      await socket.close();
      throw TailscaleTcpException(
        'Failed to send bridge auth token',
        cause: e,
      );
    }

    return socket;
  }

  /// Accepts inbound TCP connections on the tailnet. Wraps
  /// `tsnet.Server.Listen("tcp", addr)` and returns a `dart:io`
  /// [ServerSocket] so the accept loop is standard Dart.
  ///
  /// [host] restricts the listener to a specific tailnet IP of this
  /// node; leave null to accept on all tailnet IPs this node holds.
  /// Pair with [Tailscale.whois] on `conn.remoteAddress` to authorize
  /// accepted connections by ACL tag.
  Future<ServerSocket> bind(int port, {String? host}) =>
      throw UnimplementedError('tcp.bind not yet implemented');
}
