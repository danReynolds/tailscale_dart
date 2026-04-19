import 'dart:io';

/// Raw TCP primitives over the tailnet.
///
/// Verb split: [dial] for outbound connections matches Go / tsnet
/// (`Server.Dial`); [bind] for inbound listeners matches `dart:io`
/// (`ServerSocket.bind`). Using `listen` for the factory would collide
/// with `ServerSocket.listen(callback)` — the Dart stream subscription
/// that's the idiomatic accept loop.
class Tcp {
  const Tcp();

  /// Opens a TCP connection to a peer on the tailnet. Mirrors
  /// `tsnet.Server.Dial`.
  ///
  /// [host] may be a tailnet IP (e.g. `100.64.0.5`) or a MagicDNS name
  /// (e.g. `my-peer`). [timeout] applies to the dial only, not to the
  /// lifetime of the returned socket.
  Future<Socket> dial(String host, int port, {Duration? timeout}) =>
      throw UnimplementedError('tcp.dial not yet implemented');

  /// Accepts inbound TCP connections on the tailnet. Wraps
  /// `tsnet.Server.Listen("tcp", addr)` and returns a `dart:io`
  /// [ServerSocket] so the accept loop is standard Dart.
  ///
  /// [host] restricts the listener to a specific tailnet IP of this
  /// node; leave null to accept on all tailnet IPs this node holds.
  Future<ServerSocket> bind(int port, {String? host}) =>
      throw UnimplementedError('tcp.bind not yet implemented');
}
