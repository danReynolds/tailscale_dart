/// Typed Tailscale status models.
///
/// Parsed from the JSON returned by Go's `ipnstate.Status`. Only includes
/// fields useful at the application level.
library;

import 'package:meta/meta.dart';

import '_equality.dart';

/// The node's position in the connection lifecycle. Mirrors Go's
/// [`ipn.State`](https://pkg.go.dev/tailscale.com/ipn#State).
enum NodeState {
  /// No persisted credentials and the engine has not been started.
  ///
  /// This is the initial state when the node has never authenticated.
  /// An [authKey] must be provided to [Tailscale.up] to proceed.
  noState,

  /// The node needs authentication. Open
  /// [TailscaleStatus.authUrl] in a browser / web view to complete
  /// the login flow.
  needsLogin,

  /// The node is authenticated but waiting for admin approval on the
  /// control plane. See
  /// <https://tailscale.com/kb/1099/device-approval>.
  needsMachineAuth,

  /// The node is connecting to the tailnet
  /// ([WireGuard](https://www.wireguard.com/) tunnel coming up).
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
@immutable
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
  /// Open this in a browser or web view when [needsLogin] is true;
  /// the control plane will complete the flow and this node will
  /// transition to `running` once the user approves the login.
  final Uri? authUrl;

  /// This node's assigned Tailscale IP addresses — one IPv4 in the
  /// [CGNAT range](https://tailscale.com/kb/1304/ip-pool) (100.64.0.0/10)
  /// and one IPv6 in `fd7a:115c:a1e0::/48`.
  final List<String> tailscaleIPs;

  /// Health check warnings from the embedded runtime (e.g. "no
  /// connectivity to DERP servers"). Empty means all checks pass.
  final List<String> health;

  /// The [MagicDNS](https://tailscale.com/kb/1081/magicdns) suffix for
  /// the tailnet (e.g. `tailnet-name.ts.net`) — append this to any
  /// peer's hostname to get a resolvable name.
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleStatus &&
          state == other.state &&
          authUrl == other.authUrl &&
          listEquals(tailscaleIPs, other.tailscaleIPs) &&
          listEquals(health, other.health) &&
          magicDNSSuffix == other.magicDNSSuffix;

  @override
  int get hashCode => Object.hash(
        state,
        authUrl,
        Object.hashAll(tailscaleIPs),
        Object.hashAll(health),
        magicDNSSuffix,
      );

  @override
  String toString() =>
      'TailscaleStatus(state: $state, ips: $tailscaleIPs, '
      'health: $health, magicDNSSuffix: $magicDNSSuffix)';
}

/// The status of a peer on the tailnet — any other node this node
/// knows about, including offline peers.
///
/// Returned by `Tailscale.peers()`. Matches Go's
/// [`ipnstate.PeerStatus`](https://pkg.go.dev/tailscale.com/ipnstate#PeerStatus).
@immutable
class PeerStatus {
  const PeerStatus({
    required this.publicKey,
    required this.stableNodeId,
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

  /// The peer's [WireGuard](https://www.wireguard.com/) public key.
  /// Rotates whenever the peer re-registers — prefer [stableNodeId]
  /// for durable references.
  final String publicKey;

  /// Stable Tailscale node identifier (e.g. `n1234AbCd`).
  ///
  /// Prefer this over [publicKey] when naming a peer in durable state —
  /// the public key rotates when a node re-authenticates, the stable ID
  /// does not. This is the value accepted by exit-node handles (see
  /// `ExitNode.useById`).
  final String stableNodeId;

  /// The peer's hostname on the tailnet. Also the
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) label.
  final String hostName;

  /// The peer's full
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) name
  /// (for example, `my-laptop.tailnet.ts.net.`).
  ///
  /// The upstream value may be a fully-qualified domain name with a
  /// trailing dot.
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

  /// The [DERP](https://tailscale.com/kb/1232/derp-servers) relay
  /// region code in use (for example, `nyc`), or null when the path
  /// to this peer is direct (peer-to-peer WireGuard).
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
      stableNodeId: json['ID'] as String? ?? '',
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerStatus &&
          publicKey == other.publicKey &&
          stableNodeId == other.stableNodeId &&
          hostName == other.hostName &&
          dnsName == other.dnsName &&
          os == other.os &&
          listEquals(tailscaleIPs, other.tailscaleIPs) &&
          online == other.online &&
          active == other.active &&
          rxBytes == other.rxBytes &&
          txBytes == other.txBytes &&
          lastSeen == other.lastSeen &&
          relay == other.relay &&
          curAddr == other.curAddr;

  @override
  int get hashCode => Object.hash(
        publicKey,
        stableNodeId,
        hostName,
        dnsName,
        os,
        Object.hashAll(tailscaleIPs),
        online,
        active,
        rxBytes,
        txBytes,
        lastSeen,
        relay,
        curAddr,
      );

  @override
  String toString() =>
      'PeerStatus(id: $stableNodeId, hostName: $hostName, '
      'ips: $tailscaleIPs, online: $online)';
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
