/// Typed Tailscale status models.
///
/// Parsed from the JSON returned by Go's `ipnstate.Status`. Only includes
/// fields useful at the application level.

/// The node's position in the connection lifecycle.
///
/// Matches Go's `ipn.State` values. See
/// https://pkg.go.dev/tailscale.com/ipn#State
enum NodeStatus {
  /// Initial state — the engine has been created but hasn't started connecting.
  noState,

  /// The node needs authentication. Provide an auth key via [Tailscale.start].
  needsLogin,

  /// The node is authenticated but waiting for admin approval on the
  /// control plane.
  needsMachineAuth,

  /// The node is connecting to the tailnet (WireGuard tunnel coming up).
  starting,

  /// The node is connected and ready to send/receive traffic.
  running,

  /// The node has been explicitly shut down.
  stopped,
}

NodeStatus _parseNodeStatus(String? s) => switch (s) {
      'NoState' => NodeStatus.noState,
      'NeedsLogin' => NodeStatus.needsLogin,
      'NeedsMachineAuth' => NodeStatus.needsMachineAuth,
      'Starting' => NodeStatus.starting,
      'Running' => NodeStatus.running,
      'Stopped' => NodeStatus.stopped,
      _ => NodeStatus.noState,
    };

/// A snapshot of the Tailscale node's current state.
///
/// Includes the node's connection status, assigned IPs, peers on the tailnet,
/// and health information. Matches Go's `ipnstate.Status`.
class TailscaleStatus {
  const TailscaleStatus({
    required this.nodeStatus,
    this.authUrl,
    required this.tailscaleIPs,
    required this.peers,
    required this.health,
    this.magicDNSSuffix,
  });

  /// Where the node is in the connection lifecycle.
  final NodeStatus nodeStatus;

  /// Auth URL from the control plane, if login is needed.
  final String? authUrl;

  /// This node's assigned Tailscale IP addresses.
  final List<String> tailscaleIPs;

  /// All peers on the tailnet.
  final List<PeerStatus> peers;

  /// Health check warnings. Empty means healthy.
  final List<String> health;

  /// The MagicDNS suffix for the tailnet (e.g. "tailnet-name.ts.net").
  final String? magicDNSSuffix;

  /// Whether the node is connected and ready for traffic.
  bool get isRunning => nodeStatus == NodeStatus.running;

  /// Whether the node needs authentication credentials.
  bool get needsLogin => nodeStatus == NodeStatus.needsLogin;

  /// Whether all health checks are passing.
  bool get isHealthy => health.isEmpty;

  /// Online peers only.
  List<PeerStatus> get onlinePeers =>
      peers.where((p) => p.online).toList(growable: false);

  /// This node's first IPv4 address, or null.
  String? get ipv4 => tailscaleIPs
      .cast<String?>()
      .firstWhere((ip) => ip != null && ip.contains('.'), orElse: () => null);

  factory TailscaleStatus.fromJson(Map<String, dynamic> json) {
    final self = json['Self'] as Map<String, dynamic>?;
    final peerMap = json['Peer'] as Map? ?? {};

    return TailscaleStatus(
      nodeStatus: _parseNodeStatus(json['BackendState'] as String?),
      authUrl: json['AuthURL'] as String?,
      tailscaleIPs: _parseIPs(self?['TailscaleIPs']),
      peers: peerMap.values
          .map((p) =>
              PeerStatus.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(growable: false),
      health: (json['Health'] as List?)?.cast<String>() ?? const [],
      magicDNSSuffix: (json['CurrentTailnet']
          as Map<String, dynamic>?)?['MagicDNSSuffix'] as String?,
    );
  }

  /// A status representing a stopped/uninitialized engine.
  static const stopped = TailscaleStatus(
    nodeStatus: NodeStatus.stopped,
    tailscaleIPs: [],
    peers: [],
    health: [],
  );
}

/// The status of a peer on the tailnet.
///
/// Matches Go's `ipnstate.PeerStatus`.
class PeerStatus {
  const PeerStatus({
    required this.publicKey,
    required this.hostName,
    required this.dnsName,
    required this.os,
    required this.tailscaleIPs,
    required this.online,
    required this.active,
    required this.rxBytes,
    required this.txBytes,
    this.lastSeen,
    this.relay,
    this.curAddr,
  });

  /// The peer's public key.
  final String publicKey;

  /// The peer's hostname on the tailnet.
  final String hostName;

  /// The peer's MagicDNS name (e.g. "my-laptop.tailnet.ts.net.").
  final String dnsName;

  /// The peer's operating system.
  final String os;

  /// The peer's assigned Tailscale IP addresses.
  final List<String> tailscaleIPs;

  /// Whether the peer is currently online.
  final bool online;

  /// Whether there is an active connection to this peer.
  final bool active;

  /// Bytes received from this peer.
  final int rxBytes;

  /// Bytes sent to this peer.
  final int txBytes;

  /// When this peer was last seen, or null if never.
  final DateTime? lastSeen;

  /// The DERP relay region being used (e.g. "nyc"), or null if direct.
  final String? relay;

  /// The current direct address (e.g. "1.2.3.4:41641"), or null if relayed.
  final String? curAddr;

  /// This peer's first IPv4 address, or null.
  String? get ipv4 => tailscaleIPs
      .cast<String?>()
      .firstWhere((ip) => ip != null && ip.contains('.'), orElse: () => null);

  factory PeerStatus.fromJson(Map<String, dynamic> json) {
    return PeerStatus(
      publicKey: json['PublicKey'] as String? ?? '',
      hostName: json['HostName'] as String? ?? '',
      dnsName: json['DNSName'] as String? ?? '',
      os: json['OS'] as String? ?? '',
      tailscaleIPs: _parseIPs(json['TailscaleIPs']),
      online: json['Online'] as bool? ?? false,
      active: json['Active'] as bool? ?? false,
      rxBytes: json['RxBytes'] as int? ?? 0,
      txBytes: json['TxBytes'] as int? ?? 0,
      lastSeen: _parseTime(json['LastSeen']),
      relay: json['Relay'] as String?,
      curAddr: json['CurAddr'] as String?,
    );
  }
}

List<String> _parseIPs(dynamic value) {
  if (value is List) return value.cast<String>();
  return const [];
}

DateTime? _parseTime(dynamic value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
