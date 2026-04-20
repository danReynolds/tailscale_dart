/// Path type for [Diag.ping]. Matches `ipnstate.PingType`.
enum PingType {
  /// Disco pings (Tailscale's own lightweight probe).
  disco,

  /// TSMP — Tailscale's reliable-message protocol.
  tsmp,

  /// ICMP (platform-dependent; may require privileges).
  icmp,
}

/// Result of a [Diag.ping].
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
}

/// Current DERP relay map. Mirrors `tailcfg.DERPMap`.
class DERPMap {
  const DERPMap({required this.regions, required this.omitDefaultRegions});

  /// Regions keyed by region ID.
  final Map<int, DERPRegion> regions;

  /// When true, the node is configured to use only regions defined here
  /// (ignoring the built-in defaults).
  final bool omitDefaultRegions;
}

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
}

class DERPNode {
  const DERPNode({required this.name, required this.hostName});

  final String name;
  final String hostName;
}

/// A published Tailscale client version (result of [Diag.checkUpdate]).
class ClientVersion {
  const ClientVersion({
    required this.shortVersion,
    required this.longVersion,
  });

  /// Short version string, e.g. `1.92.3`.
  final String shortVersion;

  /// Full build version including git hash.
  final String longVersion;
}

/// Observability and diagnostics. All read-only; nothing here affects
/// connectivity.
///
/// Reached via [Tailscale.diag].
class Diag {
  const Diag();

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
