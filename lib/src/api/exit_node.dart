import '../status.dart';

/// Exit-node routing: route this node's internet-bound traffic
/// through another tailnet peer, VPN-style. The peer becomes the
/// last hop before the public internet, so outbound connections
/// appear to originate from its IP.
///
/// Exit-node capability is opt-in on both sides: the serving peer
/// must advertise it and be approved by an admin on the control
/// plane; any node on the tailnet can then opt into routing through
/// it. Applies only to traffic leaving the tailnet — peer-to-peer
/// tailnet traffic is unaffected.
///
/// See Tailscale's docs for the full feature (eligibility, approval,
/// split DNS behavior, LAN access):
/// <https://tailscale.com/kb/1103/exit-nodes>.
///
/// Reached via [Tailscale.exitNode].
class ExitNode {
  /// Singleton namespace instance. Reach via `Tailscale.instance.exitNode`.
  static const instance = ExitNode._();

  const ExitNode._();

  /// The peer currently being used as this node's exit, or null if none.
  Future<PeerStatus?> current() =>
      throw UnimplementedError('exitNode.current not yet implemented');

  /// The control plane's recommended exit node for this tailnet
  /// (latency-based). Returns null if no eligible peer is available.
  Future<PeerStatus?> suggest() =>
      throw UnimplementedError('exitNode.suggest not yet implemented');

  /// Routes all outbound traffic through [peer].
  ///
  /// Prefer this over [useById] — passing a [PeerStatus] you got from
  /// `Tailscale.peers()` catches stale identifiers at the type level.
  Future<void> use(PeerStatus peer) => useById(peer.stableNodeId);

  /// Escape hatch for pinning an exit node by stable node ID — useful
  /// when the caller has persisted an ID across sessions and doesn't
  /// have the full [PeerStatus] handy.
  ///
  /// [stableNodeId] is the value from [PeerStatus.stableNodeId]
  /// (e.g. `nAbCd1234`), not a public key.
  Future<void> useById(String stableNodeId) =>
      throw UnimplementedError('exitNode.useById not yet implemented');

  /// Enables `AutoExitNode` mode — the control plane picks (and
  /// re-picks, on changes) the lowest-latency eligible exit node.
  Future<void> useAuto() =>
      throw UnimplementedError('exitNode.useAuto not yet implemented');

  /// Stops routing through an exit node.
  Future<void> clear() =>
      throw UnimplementedError('exitNode.clear not yet implemented');

  /// Emits whenever the exit-node selection changes (including external
  /// changes from another device signed into the same account).
  Stream<PeerStatus?> get onCurrentChange =>
      throw UnimplementedError('exitNode.onCurrentChange not yet implemented');
}
