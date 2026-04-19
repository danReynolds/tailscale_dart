import 'dart:io';

/// Raw TCP primitives over the tailnet.
///
/// Reached via [Tailscale.tcp]. Verb naming mirrors Go's `net` /
/// `tsnet.Server`: [dial] for outbound connections (→ `Socket`),
/// [listen] for inbound listeners (→ `ServerSocket`).
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

  /// Accepts inbound TCP connections on the tailnet. Mirrors
  /// `tsnet.Server.Listen("tcp", addr)`.
  ///
  /// Returns a `dart:io` [ServerSocket] — subscribe with `.listen(...)`
  /// to accept incoming connections. (Yes, that means the call chain
  /// reads `tcp.listen(...).listen(cb)`; the first is the Go-style
  /// factory, the second is Dart's stream-subscription.)
  ///
  /// [host] restricts the listener to a specific tailnet IP of this
  /// node; leave null to accept on all tailnet IPs this node holds.
  Future<ServerSocket> listen(int port, {String? host}) =>
      throw UnimplementedError('tcp.listen not yet implemented');
}
