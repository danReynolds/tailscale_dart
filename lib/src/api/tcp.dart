import 'dart:io';

/// Raw TCP primitives over the tailnet.
///
/// Reached via [Tailscale.tcp]. All methods return standard `dart:io` types
/// (`Socket`, `ServerSocket`) so existing code that accepts those types
/// drops in unchanged.
class Tcp {
  const Tcp();

  /// Opens a TCP connection to a peer on the tailnet.
  ///
  /// [host] may be a tailnet IP (e.g. `100.64.0.5`) or a MagicDNS name
  /// (e.g. `my-peer`). [timeout] applies to the dial only, not to the
  /// lifetime of the returned socket.
  Future<Socket> dial(String host, int port, {Duration? timeout}) =>
      throw UnimplementedError('tcp.dial not yet implemented');

  /// Accepts inbound TCP connections on the tailnet.
  ///
  /// [host] restricts the bind to a specific tailnet IP of this node;
  /// leave null to accept on all tailnet IPs this node holds.
  Future<ServerSocket> bind(int port, {String? host}) =>
      throw UnimplementedError('tcp.bind not yet implemented');
}
