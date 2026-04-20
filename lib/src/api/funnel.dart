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

/// Side-channel for attaching [FunnelMetadata] to accepted [Socket]s
/// without subclassing `dart:io` types.
///
/// Exposed on the library surface (not private) so the Phase 3
/// implementation in this package can populate it; consumers only read
/// it via `socket.funnel`.
final funnelMetadata = Expando<FunnelMetadata>('FunnelMetadata');

/// Read-only accessor for Funnel metadata on an accepted [Socket].
extension FunnelSocket on Socket {
  /// The [FunnelMetadata] observed by the Funnel edge for this
  /// connection, or null when the socket was not accepted via
  /// [Funnel.bind].
  FunnelMetadata? get funnel => funnelMetadata[this];
}

/// Public-internet HTTPS via Tailscale Funnel.
///
/// Reached via [Tailscale.funnel]. Requires the tailnet operator to have
/// enabled Funnel in ACLs for this node and an allowed Funnel port
/// (typically 443, 8443, or 10000).
///
/// Accepted sockets carry a [FunnelMetadata] side-channel accessible
/// via `socket.funnel` (see [FunnelSocket]) — use that to get the
/// internet-facing source address and TLS SNI without subclassing
/// `dart:io` types.
class Funnel {
  const Funnel();

  /// Binds a TLS listener to the public internet at the node's Funnel
  /// hostname. Wraps `tsnet.Server.ListenFunnel`.
  ///
  /// If [funnelOnly] is true, connections originating from the local
  /// tailnet are rejected — use when the endpoint is intended only for
  /// external traffic. Matches Go's `FunnelOnly()` option.
  Future<SecureServerSocket> bind(int port, {bool funnelOnly = false}) =>
      throw UnimplementedError('funnel.bind not yet implemented');
}
