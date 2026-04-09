/// Typed Tailscale status models.
///
/// Parsed from the JSON returned by `DuneStatus()`. Only includes fields
/// that are useful at the application level — not the full 50+ field
/// ipnstate struct.

class TailscaleStatus {
  const TailscaleStatus({
    required this.backendState,
    this.authUrl,
    required this.tailscaleIPs,
    required this.peers,
    required this.health,
    this.magicDNSSuffix,
  });

  /// The Tailscale backend state: "NoState", "NeedsLogin",
  /// "NeedsMachineAuth", "Stopped", "Starting", "Running".
  final String backendState;

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

  bool get isRunning => backendState == 'Running';
  bool get needsLogin => backendState == 'NeedsLogin';
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
      backendState: json['BackendState'] as String? ?? 'NoState',
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

  /// Returns an empty status representing a stopped/uninitialized engine.
  static const stopped = TailscaleStatus(
    backendState: 'Stopped',
    tailscaleIPs: [],
    peers: [],
    health: [],
  );

  /// Two statuses are "same" for stream deduplication if the key fields match.
  bool sameAs(TailscaleStatus other) =>
      backendState == other.backendState &&
      tailscaleIPs.length == other.tailscaleIPs.length &&
      peers.length == other.peers.length &&
      onlinePeers.length == other.onlinePeers.length &&
      ipv4 == other.ipv4;
}

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

  final String publicKey;
  final String hostName;
  final String dnsName;
  final String os;
  final List<String> tailscaleIPs;
  final bool online;
  final bool active;
  final int rxBytes;
  final int txBytes;

  /// When this peer was last seen, or null if never.
  final DateTime? lastSeen;

  /// The DERP relay region being used, or null if direct.
  final String? relay;

  /// The current direct address, or null if relayed.
  final String? curAddr;

  /// First IPv4 address, or null.
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
