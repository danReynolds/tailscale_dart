import 'package:meta/meta.dart';

import '../_equality.dart';

/// Path type for [Diag.ping]. Matches `ipnstate.PingType`.
///
/// [disco] is the recommended default — it's Tailscale's own
/// lightweight probe, doesn't require elevated privileges, and
/// reports the real path (direct vs DERP). [icmp] crosses the
/// tunnel and uses the kernel's raw-socket stack, which typically
/// requires root / the `CAP_NET_RAW` capability.
enum PingType {
  /// Disco pings — Tailscale's own lightweight path probe.
  /// Preferred for direct-vs-DERP diagnostics.
  disco,

  /// TSMP — Tailscale's reliable-message protocol. Crosses the tunnel
  /// and exercises the full peer stack.
  tsmp,

  /// ICMP (platform-dependent; typically requires privileges).
  icmp,
}

/// How confidently [Diag.ping] could classify the route to the peer.
enum PingPath {
  /// The ping result positively identified a direct peer-to-peer path.
  direct,

  /// The ping result positively identified a DERP-relayed path.
  derp,

  /// The ping succeeded, but the chosen ping type did not expose enough
  /// routing metadata to classify the path confidently.
  unknown,
}

/// Result of a [Diag.ping].
@immutable
class PingResult {
  const PingResult({
    required this.latency,
    required this.path,
    this.derpRegion,
  });

  /// Round-trip time to the peer.
  final Duration latency;

  /// Best-effort classification of the route to the peer.
  final PingPath path;

  /// Convenience getter for callers that only care about the positive case.
  ///
  /// Returns true only when [path] is definitively [PingPath.direct].
  bool get direct => path == PingPath.direct;

  /// True when the ping was definitively routed through DERP.
  bool get isRelayed => path == PingPath.derp;

  /// DERP region code (e.g. `nyc`, `sfo`) when [path] is [PingPath.derp].
  final String? derpRegion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PingResult &&
          latency == other.latency &&
          path == other.path &&
          derpRegion == other.derpRegion;

  @override
  int get hashCode => Object.hash(latency, path, derpRegion);

  @override
  String toString() =>
      'PingResult(latency: $latency, path: $path, derpRegion: $derpRegion)';
}

/// Current DERP relay map — the set of regions and nodes Tailscale
/// will route through when a direct peer-to-peer path isn't available.
/// Mirrors `tailcfg.DERPMap`. See
/// <https://tailscale.com/kb/1232/derp-servers>.
@immutable
class DERPMap {
  const DERPMap({required this.regions, required this.omitDefaultRegions});

  /// Regions keyed by region ID.
  final Map<int, DERPRegion> regions;

  /// When true, the node is configured to use only regions defined here
  /// (ignoring the built-in defaults).
  final bool omitDefaultRegions;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DERPMap &&
          mapEquals(regions, other.regions) &&
          omitDefaultRegions == other.omitDefaultRegions;

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(
            regions.entries.map((e) => Object.hash(e.key, e.value))),
        omitDefaultRegions,
      );

  @override
  String toString() => 'DERPMap(regions: ${regions.length}, '
      'omitDefaultRegions: $omitDefaultRegions)';
}

@immutable
class DERPRegion {
  const DERPRegion({
    required this.regionId,
    required this.regionCode,
    required this.regionName,
    required this.nodes,
  });

  final int regionId;
  final String regionCode;
  final String regionName;
  final List<DERPNode> nodes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DERPRegion &&
          regionId == other.regionId &&
          regionCode == other.regionCode &&
          regionName == other.regionName &&
          listEquals(nodes, other.nodes);

  @override
  int get hashCode => Object.hash(
        regionId,
        regionCode,
        regionName,
        Object.hashAll(nodes),
      );

  @override
  String toString() =>
      'DERPRegion(id: $regionId, code: $regionCode, name: $regionName)';
}

@immutable
class DERPNode {
  const DERPNode({required this.name, required this.hostName});

  final String name;
  final String hostName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DERPNode && name == other.name && hostName == other.hostName;

  @override
  int get hashCode => Object.hash(name, hostName);

  @override
  String toString() => 'DERPNode(name: $name, hostName: $hostName)';
}

/// An available client-version update (result of [Diag.checkUpdate]).
///
/// Mirrors `tailcfg.ClientVersion`. [Diag.checkUpdate] returns null
/// when the node is already on the latest version, so the fields
/// here always describe a concrete update to apply.
@immutable
class ClientVersion {
  const ClientVersion({
    required this.latestVersion,
    required this.urgentSecurityUpdate,
    this.notifyText,
  });

  /// The newer version available for this platform (e.g. `1.94.1`).
  final String latestVersion;

  /// When true, the update includes a security fix — apply promptly.
  final bool urgentSecurityUpdate;

  /// Optional human-readable notification text from the control
  /// plane (when `Notify` is set upstream).
  final String? notifyText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientVersion &&
          latestVersion == other.latestVersion &&
          urgentSecurityUpdate == other.urgentSecurityUpdate &&
          notifyText == other.notifyText;

  @override
  int get hashCode =>
      Object.hash(latestVersion, urgentSecurityUpdate, notifyText);

  @override
  String toString() => 'ClientVersion(latest: $latestVersion, '
      'urgentSecurityUpdate: $urgentSecurityUpdate)';
}

typedef DiagPingFn = Future<PingResult> Function(
  String ip,
  Duration? timeout,
  PingType type,
);
typedef DiagMetricsFn = Future<String> Function();
typedef DiagDERPMapFn = Future<DERPMap> Function();
typedef DiagCheckUpdateFn = Future<ClientVersion?> Function();

/// Observability and diagnostics. All read-only; nothing here affects
/// connectivity.
///
/// Reached via [Tailscale.diag].
abstract class Diag {
  /// Tailscale-level ping. Reports round-trip time and whether the path
  /// is direct peer-to-peer, DERP-relayed, or not classifiable for the
  /// chosen ping type.
  Future<PingResult> ping(
    String ip, {
    Duration? timeout,
    PingType type = PingType.disco,
  });

  /// Prometheus-format metrics snapshot from the embedded runtime —
  /// peer counts, DERP activity, byte totals, handshake stats, etc.
  Future<String> metrics();

  /// Current [DERP](https://tailscale.com/kb/1232/derp-servers) relay
  /// map for this node.
  Future<DERPMap> derpMap();

  /// Checks whether a newer version of the embedded tsnet runtime is
  /// available. Returns null when already on the latest.
  Future<ClientVersion?> checkUpdate();
}

/// Library-internal factory. Reach via `Tailscale.instance.diag`.
@internal
Diag createDiag({
  required DiagPingFn pingFn,
  required DiagMetricsFn metricsFn,
  required DiagDERPMapFn derpMapFn,
  required DiagCheckUpdateFn checkUpdateFn,
}) =>
    _Diag(pingFn, metricsFn, derpMapFn, checkUpdateFn);

final class _Diag implements Diag {
  _Diag(this._ping, this._metrics, this._derpMap, this._checkUpdate);

  final DiagPingFn _ping;
  final DiagMetricsFn _metrics;
  final DiagDERPMapFn _derpMap;
  final DiagCheckUpdateFn _checkUpdate;

  @override
  Future<PingResult> ping(
    String ip, {
    Duration? timeout,
    PingType type = PingType.disco,
  }) =>
      _ping(ip, timeout, type);

  @override
  Future<String> metrics() => _metrics();

  @override
  Future<DERPMap> derpMap() => _derpMap();

  @override
  Future<ClientVersion?> checkUpdate() => _checkUpdate();
}
