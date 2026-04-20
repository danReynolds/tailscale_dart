import 'package:meta/meta.dart';

/// HTTP routing configuration for a tsnet node.
///
/// Mirrors `ipn.ServeConfig` from the Go side. The real shape is a nested
/// value type (TCP handlers, HTTPS web handlers with path-level mounts,
/// Funnel enablement per port). Stubbed here — to be modeled fully when
/// the [Serve] namespace is implemented.
///
/// [etag] is the version tag the local API returned with this config.
/// Pass it back via [Serve.setConfig] to detect concurrent writes
/// (another client editing the same config will bump the tag). Treat
/// null as "no version known" — the first [Serve.setConfig] after a
/// fresh [ServeConfig.empty] will accept any value.
@immutable
class ServeConfig {
  const ServeConfig({this.etag});

  /// An empty config with no tag — safe for the initial write.
  static const empty = ServeConfig();

  /// Opaque version tag from the last [Serve.getConfig]. Passed back
  /// via [Serve.setConfig] for optimistic concurrency.
  final String? etag;

  // TODO: model web handlers, TCP handlers, funnel enablement, services.

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ServeConfig && etag == other.etag;

  @override
  int get hashCode => etag.hashCode;

  @override
  String toString() => 'ServeConfig(etag: $etag)';
}

/// Programmatic access to the routing configuration the
/// [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve)
/// and [`tailscale funnel`](https://tailscale.com/kb/1223/funnel) CLIs
/// edit — path-prefix routing, static file serving, reverse proxying,
/// and per-port Funnel enablement.
///
/// Reached via [Tailscale.serve]. The API is intentionally minimal —
/// get the current config, transform it as an immutable value
/// client-side, push the new one. All the addRoute/removeRoute
/// operations compose as transforms on [ServeConfig], not methods on
/// this class.
class Serve {
  /// Library-internal. Reach via `Tailscale.instance.serve`.
  @internal
  const Serve.internal();

  /// Current serve/funnel config for this node.
  Future<ServeConfig> getConfig() =>
      throw UnimplementedError('serve.getConfig not yet implemented');

  /// Replaces the full config atomically.
  ///
  /// Uses optimistic concurrency — the [ServeConfig.etag] from
  /// [getConfig] must still be current. On mismatch, throws
  /// [TailscaleServeException] with
  /// [TailscaleErrorCode.conflict]; the caller should re-fetch,
  /// reapply their transform, and retry.
  Future<void> setConfig(ServeConfig config) =>
      throw UnimplementedError('serve.setConfig not yet implemented');
}
