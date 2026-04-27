import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'connection.dart';

typedef TcpDialFn =
    Future<({int fd, TailscaleEndpoint local, TailscaleEndpoint remote})>
    Function(String host, int port, Duration? timeout);

typedef TcpListenFn =
    Future<({int listenerId, TailscaleEndpoint local})> Function(
      int tailnetPort,
      String tailnetHost,
    );

typedef TcpCloseListenerFn = Future<void> Function(int listenerId);

/// Raw TCP primitives between tailnet nodes.
///
/// TCP is exposed as package-native [TailscaleConnection] and
/// [TailscaleListener] types rather than fake `dart:io` sockets. Go owns the
/// tailnet connection establishment and hands Dart a private local data-plane
/// capability; Dart owns application-facing stream lifecycle.
abstract class Tcp {
  /// Opens a TCP connection to a node on the tailnet.
  ///
  /// [host] may be a tailnet IP (for example `100.64.0.5`) or a MagicDNS name
  /// (for example `my-node` or `my-node.tailnet.ts.net`). [timeout] bounds the
  /// native tailnet dial only, not the lifetime of the returned connection.
  ///
  /// Throws [TailscaleTcpException] on tailnet-side failures such as no route,
  /// refused connection, or use before the embedded node is running.
  Future<TailscaleConnection> dial(String host, int port, {Duration? timeout});

  /// Accepts inbound TCP connections on the tailnet.
  ///
  /// [port] is the tailnet port to bind. Pass `0` to request an ephemeral
  /// tailnet port, then read it from the returned [TailscaleListener.local].
  ///
  /// [address] restricts the listener to a specific tailnet IP of this node;
  /// leave null to accept on all tailnet IPs this node holds.
  Future<TailscaleListener> bind({required int port, String? address});
}

/// Library-internal factory. Reach via `Tailscale.instance.tcp`.
@internal
Tcp createTcp({
  required TcpDialFn dialFn,
  required TcpListenFn listenFn,
  required TcpCloseListenerFn closeListenerFn,
}) => _Tcp(dialFn, listenFn, closeListenerFn);

final class _Tcp implements Tcp {
  _Tcp(this._dial, this._listen, this._closeListener);

  final TcpDialFn _dial;
  final TcpListenFn _listen;
  final TcpCloseListenerFn _closeListener;

  @override
  Future<TailscaleConnection> dial(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    if (Platform.isWindows) {
      throw const TailscaleTcpException('Windows is not supported.');
    }
    try {
      final (:fd, :local, :remote) = await _dial(host, port, timeout);
      return createFdTailscaleConnection(fd: fd, local: local, remote: remote);
    } catch (e) {
      if (e is TailscaleTcpException) rethrow;
      throw TailscaleTcpException('tcp.dial failed for $host:$port', cause: e);
    }
  }

  @override
  Future<TailscaleListener> bind({required int port, String? address}) async {
    if (Platform.isWindows) {
      throw const TailscaleTcpException('Windows is not supported.');
    }
    try {
      final (:listenerId, :local) = await _listen(port, address ?? '');
      return createFdTailscaleListener(
        listenerId: listenerId,
        local: local,
        closeFn: _closeListener,
      );
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleTcpException(
        'tcp.bind failed for tailnet port $port',
        cause: e,
      );
    }
  }
}
