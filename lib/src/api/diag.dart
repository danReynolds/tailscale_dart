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

/// Result of a [Diag.ping].
@immutable
class PingResult {
  const PingResult({
    required this.latency,
    required this.direct,
    this.derpRegion,
  });

  /// Round-trip time to the peer.
  final Duration latency;

  /// True if the path is direct peer-to-peer (WireGuard), false if routed
  /// through a DERP relay.
  final bool direct;

  /// DERP region code (e.g. `nyc`, `sfo`) when [direct] is false.
  final String? derpRegion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PingResult &&
          latency == other.latency &&
          direct == other.direct &&
          derpRegion == other.derpRegion;

  @override
  int get hashCode => Object.hash(latency, direct, derpRegion);

  @override
  String toString() =>
      'PingResult(latency: $latency, direct: $direct, derpRegion: $derpRegion)';
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

/// A published Tailscale client version (result of [Diag.checkUpdate]).
@immutable
class ClientVersion {
  const ClientVersion({
    required this.shortVersion,
    required this.longVersion,
  });

  /// Short version string, e.g. `1.92.3`.
  final String shortVersion;

  /// Full build version including git hash.
  final String longVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientVersion &&
          shortVersion == other.shortVersion &&
          longVersion == other.longVersion;

  @override
  int get hashCode => Object.hash(shortVersion, longVersion);

  @override
  String toString() =>
      'ClientVersion(short: $shortVersion, long: $longVersion)';
}

/// Observability and diagnostics. All read-only; nothing here affects
/// connectivity.
///
/// Reached via [Tailscale.diag].
class Diag {
  /// Singleton namespace instance. Reach via `Tailscale.instance.diag`.
  static const instance = Diag._();

  const Diag._();

  /// Tailscale-level ping. Reports round-trip time and whether the path
  /// is direct peer-to-peer or DERP-relayed.
  Future<PingResult> ping(
    String ip, {
    Duration? timeout,
    PingType type = PingType.disco,
  }) =>
      throw UnimplementedError('diag.ping not yet implemented');

  /// Prometheus-format metrics snapshot from the embedded runtime — peer
  /// counts, DERP activity, byte totals, handshake stats, etc.
  Future<String> metrics() =>
      throw UnimplementedError('diag.metrics not yet implemented');

  /// Current DERP relay map.
  Future<DERPMap> derpMap() =>
      throw UnimplementedError('diag.derpMap not yet implemented');

  /// The latest available tsnet version if newer than the embedded one,
  /// else null.
  Future<ClientVersion?> checkUpdate() =>
      throw UnimplementedError('diag.checkUpdate not yet implemented');
}
