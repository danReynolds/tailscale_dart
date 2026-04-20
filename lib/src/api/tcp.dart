import 'dart:io';

import 'package:meta/meta.dart';

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
  const Tcp.internal();

  /// Opens a TCP connection to a peer on the tailnet. Mirrors
  /// `tsnet.Server.Dial`.
  ///
  /// [host] may be a tailnet IP (e.g. `100.64.0.5`) or a
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) name
  /// (e.g. `my-peer` or `my-peer.tailnet.ts.net`). [timeout] applies
  /// to the dial only, not to the lifetime of the returned socket.
  Future<Socket> dial(String host, int port, {Duration? timeout}) =>
      throw UnimplementedError('tcp.dial not yet implemented');

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
