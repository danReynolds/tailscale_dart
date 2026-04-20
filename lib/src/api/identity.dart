/// Identity of a tailnet node (the result of [Tailscale.whois]).
///
/// Tagged-node auth uses [tags]; user-owned nodes use [userLoginName].
class PeerIdentity {
  const PeerIdentity({
    required this.nodeId,
    required this.hostName,
    required this.userLoginName,
    required this.tags,
    required this.tailscaleIPs,
  });

  /// Stable Tailscale node identifier (e.g. `n1234AbCd`).
  final String nodeId;

  /// Tailnet-visible hostname.
  final String hostName;

  /// Owning user's login name (e.g. `alice@example.com`), or empty for
  /// tagged nodes.
  final String userLoginName;

  /// ACL tags attached to the node (e.g. `['tag:server', 'tag:prod']`).
  final List<String> tags;

  /// Tailscale IP addresses assigned to this node.
  final List<String> tailscaleIPs;
}
