import 'dart:io';

import 'package:meta/meta.dart';

/// UDP datagram primitives over the tailnet.
///
/// Reached via [Tailscale.udp].
class Udp {
  /// Library-internal. Reach via `Tailscale.instance.udp`.
  @internal
  const Udp.internal();

  /// Binds a UDP datagram socket on a specific tailnet IP of this node.
  /// Wraps `tsnet.Server.ListenPacket`.
  ///
  /// Unlike [Tcp.bind], [host] is required and must be a valid tailnet
  /// address on this node — it cannot be `0.0.0.0`. Use
  /// `(await tsnet.status()).ipv4` to pick one.
  Future<RawDatagramSocket> bind(String host, int port) =>
      throw UnimplementedError('udp.bind not yet implemented');
}
