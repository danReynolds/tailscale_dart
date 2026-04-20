import 'dart:io';

/// Public-internet HTTPS via Tailscale Funnel.
///
/// Reached via [Tailscale.funnel]. Requires the tailnet operator to have
/// enabled Funnel in ACLs for this node and an allowed Funnel port
/// (typically 443, 8443, or 10000).
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
