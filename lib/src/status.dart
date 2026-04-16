/// Typed Tailscale status models.
///
/// Parsed from the JSON returned by Go's `ipnstate.Status`. Only includes
/// fields useful at the application level.
library;

/// The node's position in the connection lifecycle.
///
/// Matches Go's `ipn.State` values. See
/// https://pkg.go.dev/tailscale.com/ipn#State
enum NodeState {
  /// No persisted credentials and the engine has not been started.
  ///
  /// This is the initial state when the node has never authenticated.
  /// An [authKey] must be provided to [Tailscale.up] to proceed.
  noState,

  /// The node needs authentication. Provide an auth key via [Tailscale.up].
  needsLogin,

  /// The node is authenticated but waiting for admin approval on the
  /// control plane.
  needsMachineAuth,

  /// The node is connecting to the tailnet (WireGuard tunnel coming up).
  starting,

  /// The node is connected and ready to send/receive traffic.
  running,

  /// The engine is not running but persisted credentials exist.
  ///
  /// Returned by [Tailscale.status] when the node was previously
  /// authenticated but [Tailscale.up] has not been called yet, or after
  /// [Tailscale.down]. The next [Tailscale.up] can reconnect without an
  /// auth key.
  stopped;

  /// Parses a Go `ipn.State` string into a [NodeState].
  static NodeState parse(String? s) => switch (s) {
    'NoState' => NodeState.noState,
    'NeedsLogin' => NodeState.needsLogin,
    'NeedsMachineAuth' => NodeState.needsMachineAuth,
    'Starting' => NodeState.starting,
    'Running' => NodeState.running,
    'Stopped' => NodeState.stopped,
    _ => NodeState.noState,
  };
}

/// A snapshot of the local node's current state.
///
/// Includes the node's connection status, assigned IPs, and health
/// information. Peer inventory is exposed separately through `Tailscale.peers`.
class TailscaleStatus {
  const TailscaleStatus({
    required this.state,
    this.authUrl,
    required this.tailscaleIPs,
    required this.health,
    this.magicDNSSuffix,
  });

  /// Where the node is in the connection lifecycle.
  final NodeState state;

  /// Login URL from the control plane, if authentication is required.
  ///
  /// Open this in a browser or web view when [needsLogin] is true.
  final Uri? authUrl;

  /// This node's assigned Tailscale IP addresses.
  final List<String> tailscaleIPs;

  /// Health check warnings. Empty means healthy.
  final List<String> health;

  /// The MagicDNS suffix for the tailnet (e.g. "tailnet-name.ts.net").
  ///
  /// May be null when tailnet metadata is not yet available.
  final String? magicDNSSuffix;

  /// Whether the node is connected and ready for traffic.
  bool get isRunning => state == NodeState.running;

  /// Whether the node needs authentication credentials.
  bool get needsLogin => state == NodeState.needsLogin;

  /// Whether all health checks are passing.
  bool get isHealthy => health.isEmpty;

  /// This node's first IPv4 address, or null.
  String? get ipv4 => tailscaleIPs.firstIpv4;

  /// Parses a status snapshot from the JSON shape produced by Go's
  /// `ipnstate.Status`.
  ///
  /// Missing or malformed fields fall back to safe defaults (empty lists,
  /// [NodeState.noState]) rather than throwing — callers should treat the
  /// result as a best-effort view of the engine's reported state.
  factory TailscaleStatus.fromJson(Map<String, dynamic> json) {
    final self = json['Self'] as Map<String, dynamic>?;

    return TailscaleStatus(
      state: NodeState.parse(json['BackendState'] as String?),
      authUrl: _parseUri(json['AuthURL']),
      tailscaleIPs: _parseIPs(self?['TailscaleIPs']),
      health: (json['Health'] as List?)?.cast<String>() ?? const [],
      magicDNSSuffix:
          (json['CurrentTailnet'] as Map<String, dynamic>?)?['MagicDNSSuffix']
              as String?,
    );
  }

  /// A status representing a stopped/uninitialized engine.
  static const stopped = TailscaleStatus(
    state: NodeState.stopped,
    tailscaleIPs: [],
    health: [],
  );
}

/// The status of a peer on the tailnet.
///
/// Returned by `Tailscale.peers()`. Matches Go's `ipnstate.PeerStatus`.
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

  /// The peer's WireGuard public key.
  final String publicKey;

  /// The peer's hostname on the tailnet.
  final String hostName;

  /// The peer's MagicDNS name (for example, `my-laptop.tailnet.ts.net.`).
  ///
  /// The upstream value may be a fully-qualified domain name with a trailing
  /// dot.
  final String dnsName;

  /// The peer's operating system.
  final String os;

  /// The peer's assigned Tailscale IP addresses.
  final List<String> tailscaleIPs;

  /// Whether the peer is currently online.
  final bool online;

  /// Whether Tailscale currently considers this peer active.
  ///
  /// This is a useful hint for UI/diagnostics, but should be treated as a
  /// heuristic rather than a strict connectivity guarantee.
  final bool active;

  /// Bytes received from this peer.
  final int rxBytes;

  /// Bytes sent to this peer.
  final int txBytes;

  /// When this peer was last seen, or null if never.
  ///
  /// Most useful for offline peers.
  final DateTime? lastSeen;

  /// The DERP relay region code in use (for example, `nyc`), or null if direct.
  final String? relay;

  /// The current direct address in `host:port` form, or null if relayed.
  ///
  /// Primarily useful for diagnostics.
  final String? curAddr;

  /// This peer's first IPv4 address, or null.
  String? get ipv4 => tailscaleIPs.firstIpv4;

  /// Parses a peer snapshot list returned by `Tailscale.peers()`.
  static List<PeerStatus> listFromJson(List<dynamic> json) {
    return json
        .map((peer) => PeerStatus.fromJson(Map<String, dynamic>.from(peer)))
        .toList(growable: false);
  }

  /// Parses a single peer from the JSON shape produced by Go's
  /// `ipnstate.PeerStatus`.
  ///
  /// Missing or malformed fields fall back to safe defaults (empty strings,
  /// `false`, `0`) rather than throwing.
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

extension on List<String> {
  String? get firstIpv4 {
    for (final ip in this) {
      if (ip.contains('.')) return ip;
    }
    return null;
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

Uri? _parseUri(dynamic value) {
  if (value is String && value.isNotEmpty) {
    return Uri.tryParse(value);
  }
  return null;
}
