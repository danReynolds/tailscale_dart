import 'dart:async';
import 'dart:convert';
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
    required Future<int> Function(
      int tailnetPort,
      String tailnetHost,
      int loopbackPort,
    ) bindFn,
    required Future<void> Function(int loopbackPort) unbindFn,
  })  : _dialFn = dialFn,
        _bindFn = bindFn,
        _unbindFn = unbindFn;

  final Future<({int loopbackPort, String token})> Function(
    String host,
    int port,
    Duration? timeout,
  ) _dialFn;
  final Future<int> Function(
    int tailnetPort,
    String tailnetHost,
    int loopbackPort,
  ) _bindFn;
  final Future<void> Function(int loopbackPort) _unbindFn;

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
  Future<Socket> dial(String host, int port, {Duration? timeout}) async {
    Stopwatch? stopwatch;
    if (timeout != null) {
      stopwatch = Stopwatch()..start();
    }

    final (:loopbackPort, :token) = await _dialFn(host, port, timeout);

    late Socket socket;
    try {
      final remaining = _remainingTimeout(stopwatch, timeout);
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        loopbackPort,
        timeout: remaining,
      );
    } on TailscaleTcpException {
      // Budget already exhausted by _remainingTimeout — propagate as-is.
      rethrow;
    } catch (e) {
      throw TailscaleTcpException(
        'Failed to connect to loopback bridge on port $loopbackPort',
        cause: e,
      );
    }

    try {
      _remainingTimeout(stopwatch, timeout);
      socket.add(utf8.encode(token));
      await socket.flush();
    } on TailscaleTcpException {
      await socket.close();
      rethrow;
    } catch (e) {
      await socket.close();
      throw TailscaleTcpException(
        'Failed to send bridge auth token',
        cause: e,
      );
    }

    return socket;
  }

  static Duration? _remainingTimeout(
    Stopwatch? stopwatch,
    Duration? totalTimeout,
  ) {
    if (stopwatch == null || totalTimeout == null) return null;
    final remaining = totalTimeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw TailscaleTcpException(
        'tcp.dial exceeded its timeout budget before the loopback bridge '
        'handshake completed.',
      );
    }
    return remaining;
  }

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
  Future<ServerSocket> bind(int port, {String? host}) async {
    final loopback = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );

    int boundTailnetPort;
    try {
      boundTailnetPort = await _bindFn(port, host ?? '', loopback.port);
    } catch (e) {
      await loopback.close();
      if (e is TailscaleException) rethrow;
      throw TailscaleTcpException(
        'Failed to bind tailnet port $port',
        cause: e,
      );
    }

    return _UnbindingServerSocket(
      loopback,
      boundTailnetPort,
      () => _unbindFn(loopback.port),
    );
  }
}

/// `ServerSocket` delegate that surfaces the tailnet port as
/// [ServerSocket.port] and runs an extra teardown hook after
/// `close()` so the Go-side tailnet listener is torn down when the
/// caller closes their handle.
class _UnbindingServerSocket extends StreamView<Socket>
    implements ServerSocket {
  _UnbindingServerSocket(
    this._delegate,
    this._tailnetPort,
    this._onClose,
  ) : super(_delegate);

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
    // Best-effort — the Go side may already be down.
    try {
      await _onClose();
    } catch (_) {}
    return this;
  }
}
