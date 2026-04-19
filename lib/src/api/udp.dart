import 'dart:io';

/// UDP datagram primitives over the tailnet.
///
/// Reached via [Tailscale.udp].
class Udp {
  const Udp();

  /// Opens a UDP datagram socket on a specific tailnet IP of this node.
  /// Mirrors `tsnet.Server.ListenPacket` (the "Packet" suffix upstream
  /// disambiguates from TCP `Listen`; here the `udp` namespace already
  /// disambiguates).
  ///
  /// Unlike [Tcp.listen], [host] is required and must be a valid
  /// tailnet address on this node — it cannot be `0.0.0.0`. Use
  /// `(await tsnet.status()).ipv4` to pick one.
  Future<RawDatagramSocket> listen(String host, int port) =>
      throw UnimplementedError('udp.listen not yet implemented');
}
