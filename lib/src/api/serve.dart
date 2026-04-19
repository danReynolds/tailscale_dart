/// HTTP routing configuration for a tsnet node.
///
/// Mirrors `ipn.ServeConfig` from the Go side. The real shape is a nested
/// value type (TCP handlers, HTTPS web handlers with path-level mounts,
/// Funnel enablement per port). Stubbed here — to be modeled fully when
/// the [Serve] namespace is implemented.
class ServeConfig {
  const ServeConfig();

  // TODO: model web handlers, TCP handlers, funnel enablement, etags.
}

/// HTTP routing (`tailscale serve`) + public-internet publishing
/// (`tailscale funnel`) config.
///
/// Reached via [Tailscale.serve]. The API is intentionally minimal — get
/// the current config, transform it as an immutable value client-side,
/// push the new one. All the addRoute/removeRoute operations compose as
/// transforms on [ServeConfig], not methods on this class.
class Serve {
  const Serve();

  /// Current serve/funnel config for this node.
  Future<ServeConfig> getConfig() =>
      throw UnimplementedError('serve.getConfig not yet implemented');

  /// Replaces the full config atomically.
  Future<void> setConfig(ServeConfig config) =>
      throw UnimplementedError('serve.setConfig not yet implemented');
}
