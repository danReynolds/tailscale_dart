import 'package:meta/meta.dart';

/// Identity of a tailnet node — the result of [Tailscale.whois].
///
/// Combine with [Tailscale.tcp] `.bind(...)` to authorize incoming
/// connections by identity: resolve the peer via `whois`, then
/// check [tags] for tagged-node auth or [userLoginName] for
/// user-owned nodes. Tags are the preferred mechanism for
/// service-to-service auth on a tailnet; see
/// <https://tailscale.com/kb/1068/tags>.
@immutable
class PeerIdentity {
  const PeerIdentity({
    required this.nodeId,
    required this.hostName,
    required this.userLoginName,
    required this.tags,
    required this.tailscaleIPs,
  });

  /// Stable Tailscale node identifier (e.g. `n1234AbCd`). Persists
  /// across key rotations; prefer over public keys for durable
  /// identity references.
  final String nodeId;

  /// Tailnet-visible hostname. Also the MagicDNS label (so the peer
  /// is reachable at `<hostName>.<tailnet>.ts.net`).
  final String hostName;

  /// Owning user's login name (e.g. `alice@example.com`), or empty for
  /// [tagged nodes](https://tailscale.com/kb/1068/tags).
  final String userLoginName;

  /// [ACL tags](https://tailscale.com/kb/1068/tags) attached to the
  /// node (e.g. `['tag:server', 'tag:prod']`). Empty for user-owned
  /// nodes.
  final List<String> tags;

  /// Tailscale IP addresses assigned to this node.
  final List<String> tailscaleIPs;

  @override
  String toString() =>
      'PeerIdentity(nodeId: $nodeId, hostName: $hostName, '
      'userLoginName: $userLoginName, tags: $tags)';
}
