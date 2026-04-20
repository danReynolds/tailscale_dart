import 'dart:io';

import 'package:meta/meta.dart';

/// Metadata attached by the Funnel edge to each accepted connection —
/// the public source address observed on the internet-facing side, and
/// the TLS SNI the client used to reach this node.
///
/// Access via `socket.funnel` (see the [FunnelSocket] extension) on a
/// [Socket] obtained from the [SecureServerSocket] returned by
/// [Funnel.bind]. Null when the socket came from somewhere else.
@immutable
class FunnelMetadata {
  const FunnelMetadata({required this.publicSrc, this.sni});

  /// Public `host:port` the Funnel edge observed. Use this for rate
  /// limiting / geo lookups, not the socket's local address.
  final String publicSrc;

  /// SNI (server-name indication) presented by the client during the
  /// TLS handshake, or null if none.
  final String? sni;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunnelMetadata &&
          publicSrc == other.publicSrc &&
          sni == other.sni;

  @override
  int get hashCode => Object.hash(publicSrc, sni);

  @override
  String toString() => 'FunnelMetadata(publicSrc: $publicSrc, sni: $sni)';
}

/// Side-channel Expando keyed by accepted [Socket]. Private so consumers
/// can only read it through the [FunnelSocket] extension; writes go
/// through [attachFunnelMetadata] which is marked `@internal`.
final _funnelMetadata = Expando<FunnelMetadata>('FunnelMetadata');

/// Attach [metadata] to an accepted Funnel [socket] so callers can read
/// it via `socket.funnel`.
///
/// Library-internal — called by this package's Phase 5 Funnel
/// implementation when yielding accepted sockets on the
/// [SecureServerSocket] stream. Consumers never need to call this.
@internal
void attachFunnelMetadata(Socket socket, FunnelMetadata metadata) {
  _funnelMetadata[socket] = metadata;
}

/// Read-only accessor for Funnel metadata on an accepted [Socket].
extension FunnelSocket on Socket {
  /// The [FunnelMetadata] observed by the Funnel edge for this
  /// connection, or null when the socket was not accepted via
  /// [Funnel.bind].
  FunnelMetadata? get funnel => _funnelMetadata[this];
}

/// Public-internet HTTPS via Tailscale Funnel: expose this node to the
/// open internet (not just the tailnet) at `https://<node>.<tailnet>.ts.net`,
/// with edge TLS termination by Tailscale's Funnel relay. The cert is
/// auto-provisioned (same mechanism as [Tls]), and traffic is proxied
/// from the Funnel edge through the tailnet to this node.
///
/// See <https://tailscale.com/kb/1223/funnel> for the full feature
/// (ACL configuration, allowed ports, rate limits).
///
/// Reached via [Tailscale.funnel]. Requires:
/// - Funnel enabled for this node in the tailnet's
///   [ACLs](https://tailscale.com/kb/1018/acls) (operator action —
///   check with an admin if [bind] returns a `featureDisabled` error).
/// - One of Tailscale's allowed Funnel ports: **443**, **8443**,
///   or **10000**.
///
/// Accepted sockets carry a [FunnelMetadata] side-channel accessible
/// via `socket.funnel` (see [FunnelSocket]) — use that to get the
/// internet-facing source address and TLS SNI without subclassing
/// `dart:io` types.
class Funnel {
  /// Singleton namespace instance. Reach via `Tailscale.instance.funnel`.
  static const instance = Funnel._();

  const Funnel._();

  /// Binds a TLS listener to the public internet at the node's Funnel
  /// hostname. Wraps `tsnet.Server.ListenFunnel`.
  ///
  /// If [funnelOnly] is true, connections originating from the local
  /// tailnet are rejected — use when the endpoint is intended only for
  /// external traffic. Matches Go's `FunnelOnly()` option.
  Future<SecureServerSocket> bind(int port, {bool funnelOnly = false}) =>
      throw UnimplementedError('funnel.bind not yet implemented');
}
