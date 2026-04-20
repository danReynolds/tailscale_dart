import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../errors.dart';

typedef TcpDialFn = Future<({int loopbackPort, String token})> Function(
  String host,
  int port,
  Duration? timeout,
);
typedef TcpBindFn = Future<int> Function(
  int tailnetPort,
  String tailnetHost,
  int loopbackPort,
);
typedef TcpUnbindFn = Future<void> Function(int loopbackPort);

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
abstract class Tcp {
  /// Opens a TCP connection to a peer on the tailnet. Mirrors
  /// `tsnet.Server.Dial`.
  ///
  /// [host] may be a tailnet IP (e.g. `100.64.0.5`) or a
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) name
  /// (e.g. `my-peer` or `my-peer.tailnet.ts.net`). [timeout] is one
  /// end-to-end budget across the native tailnet dial, the Dart-side
  /// loopback connect, and the token handshake only — not the lifetime
  /// of the returned socket.
  ///
  /// Implemented as a one-shot loopback bridge: the embedded Go
  /// runtime opens the tailnet conn and pipes bytes through a
  /// per-call 127.0.0.1 listener. A random per-call token is written
  /// as the first bytes on the wire so co-resident processes can't
  /// hijack the bridge. The Go-side listener keeps accepting until
  /// a valid-token client arrives or the overall timeout elapses —
  /// a co-resident attacker sending a bad token wastes their own
  /// socket but doesn't consume the bridge.
  ///
  /// Throws [TailscaleTcpException] on tailnet-side failures (no
  /// route, connection refused, etc.) or if the loopback bridge
  /// handshake fails.
  Future<Socket> dial(String host, int port, {Duration? timeout});

  /// Accepts inbound TCP connections on the tailnet. Wraps
  /// `tsnet.Server.Listen("tcp", addr)` and returns a `dart:io`
  /// [ServerSocket] so the accept loop is standard Dart.
  ///
  /// [port] is the tailnet port to bind — pass `0` to request an
  /// ephemeral port, then read it back from the returned
  /// [ServerSocket.port].
  ///
  /// [host] restricts the listener to a specific tailnet IP of this
  /// node; leave null to accept on all tailnet IPs this node holds.
  /// Pair with [Tailscale.whois] on `conn.remoteAddress` to authorize
  /// accepted connections by ACL tag.
  ///
  /// Implementation: Dart owns an ephemeral 127.0.0.1 [ServerSocket];
  /// the Go side runs the tsnet listener and dials the loopback on
  /// each accepted tailnet connection. Closing the returned
  /// [ServerSocket] tears down the tailnet listener via a proactive
  /// unbind call.
  ///
  /// The returned [ServerSocket.port] reports the **tailnet port**
  /// (what peers connect to), not the internal loopback port. The
  /// [ServerSocket.address] still reflects the local loopback
  /// (127.0.0.1), since the tailnet side is the tsnet runtime's
  /// abstraction, not a local interface.
  ///
  /// Note: no per-connection authentication on the loopback side.
  /// Co-resident processes could theoretically connect to the
  /// ephemeral loopback port and impersonate a tailnet peer. If
  /// this matters for your threat model, add an application-level
  /// handshake on top.
  Future<ServerSocket> bind(int port, {String? host});
}

/// Library-internal factory. Reach via `Tailscale.instance.tcp`.
@internal
Tcp createTcp({
  required TcpDialFn dialFn,
  required TcpBindFn bindFn,
  required TcpUnbindFn unbindFn,
}) =>
    _Tcp(dialFn, bindFn, unbindFn);

final class _Tcp implements Tcp {
  _Tcp(this._dial, this._bind, this._unbind);

  final TcpDialFn _dial;
  final TcpBindFn _bind;
  final TcpUnbindFn _unbind;

  @override
  Future<Socket> dial(String host, int port, {Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    final (:loopbackPort, :token) = await _dial(host, port, timeout);

    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        loopbackPort,
        timeout: _remaining(deadline),
      );
      socket.add(utf8.encode(token));
      await socket.flush();
      return socket;
    } catch (e) {
      await socket?.close().catchError((_) {});
      if (e is TailscaleTcpException) rethrow;
      throw TailscaleTcpException(
        'tcp.dial loopback bridge failed on port $loopbackPort',
        cause: e,
      );
    }
  }

  @override
  Future<ServerSocket> bind(int port, {String? host}) async {
    final loopback = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final tailnetPort = await _bind(port, host ?? '', loopback.port);
      return _UnbindingServerSocket(
        loopback,
        tailnetPort,
        () => _unbind(loopback.port),
      );
    } catch (e) {
      await loopback.close();
      if (e is TailscaleException) rethrow;
      throw TailscaleTcpException(
        'tcp.bind failed for tailnet port $port',
        cause: e,
      );
    }
  }

  static Duration? _remaining(DateTime? deadline) {
    if (deadline == null) return null;
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const TailscaleTcpException(
        'tcp.dial exceeded its timeout budget before the loopback bridge '
        'handshake completed.',
      );
    }
    return remaining;
  }
}

/// `ServerSocket` delegate that surfaces the tailnet port as
/// [ServerSocket.port] and fires an unbind hook after `close()` so the
/// Go-side tailnet listener tears down with the caller's handle.
class _UnbindingServerSocket extends StreamView<Socket>
    implements ServerSocket {
  _UnbindingServerSocket(this._delegate, this._tailnetPort, this._onClose)
      : super(_delegate);

  final ServerSocket _delegate;
  final int _tailnetPort;
  final Future<void> Function() _onClose;

  @override
  InternetAddress get address => _delegate.address;

  @override
  int get port => _tailnetPort;

  @override
  Future<ServerSocket> close() async {
    await _delegate.close();
    try {
      await _onClose();
    } catch (_) {}
    return this;
  }
}
