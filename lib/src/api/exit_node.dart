import '../status.dart';

/// Exit-node routing: route all outbound traffic from this node through
/// a peer, VPN-style.
///
/// Reached via [Tailscale.exitNode].
class ExitNode {
  const ExitNode();

  /// The peer currently being used as this node's exit, or null if none.
  Future<PeerStatus?> current() =>
      throw UnimplementedError('exitNode.current not yet implemented');

  /// The control plane's recommended exit node for this tailnet
  /// (latency-based). Returns null if no eligible peer is available.
  Future<PeerStatus?> suggest() =>
      throw UnimplementedError('exitNode.suggest not yet implemented');

  /// Routes all outbound traffic through the peer with [peerPublicKey].
  Future<void> use(String peerPublicKey) =>
      throw UnimplementedError('exitNode.use not yet implemented');

  /// Stops routing through an exit node.
  Future<void> clear() =>
      throw UnimplementedError('exitNode.clear not yet implemented');

  /// Emits whenever the exit-node selection changes (including external
  /// changes from another device signed into the same account).
  Stream<PeerStatus?> get onCurrentChange =>
      throw UnimplementedError('exitNode.onCurrentChange not yet implemented');
}
