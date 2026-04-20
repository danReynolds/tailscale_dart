/// Node preferences. Mirrors a subset of `ipn.Prefs` on the Go side.
///
/// Fields cover the long tail of tsnet configuration that doesn't warrant
/// its own top-level namespace. Use [Prefs.get] to read; use the named
/// setters on [Prefs] (`advertiseRoutes(...)`, `setShieldsUp(true)`, etc.)
/// for common single-field changes, or [Prefs.updateMasked] for atomic
/// multi-field edits.
class TailscalePrefs {
  const TailscalePrefs({
    required this.advertiseRoutes,
    required this.acceptRoutes,
    required this.shieldsUp,
    required this.advertiseTags,
    required this.wantRunning,
    required this.autoUpdate,
    required this.hostname,
    this.exitNodeId,
  });

  /// CIDRs this node advertises as subnet routes.
  final List<String> advertiseRoutes;

  /// Accept subnet routes advertised by other nodes.
  final bool acceptRoutes;

  /// When true, no inbound connections are accepted.
  final bool shieldsUp;

  /// ACL tags to advertise when registering the node.
  final List<String> advertiseTags;

  /// Whether the engine should be connected (i.e. not manually paused).
  final bool wantRunning;

  /// Auto-update the underlying tsnet when a newer version is released.
  final bool autoUpdate;

  /// The tailnet-visible hostname for this node.
  final String hostname;

  /// Stable node ID currently in use as an exit node, or null if none.
  final String? exitNodeId;
}

/// A multi-field atomic update to [TailscalePrefs]. Only fields set on
/// this object are modified; unset fields are left alone.
///
/// Mirrors `ipn.MaskedPrefs` on the Go side.
class MaskedPrefs {
  const MaskedPrefs({
    this.advertiseRoutes,
    this.acceptRoutes,
    this.shieldsUp,
    this.advertiseTags,
    this.wantRunning,
    this.autoUpdate,
    this.hostname,
    this.exitNodeId,
  });

  final List<String>? advertiseRoutes;
  final bool? acceptRoutes;
  final bool? shieldsUp;
  final List<String>? advertiseTags;
  final bool? wantRunning;
  final bool? autoUpdate;
  final String? hostname;

  /// Pass empty string to clear the current exit node; `null` leaves
  /// unchanged (Dart's single-null problem; use named setters for clarity).
  final String? exitNodeId;
}

/// Low-level escape hatch for preferences that don't have a dedicated
/// namespace — subnet routes, Shields Up, auto-update opt-in, tags, etc.
///
/// Reached via [Tailscale.prefs]. For common single-field changes prefer
/// the named setters; for atomic multi-field edits use [updateMasked].
class Prefs {
  const Prefs();

  /// Current preferences snapshot.
  Future<TailscalePrefs> get() =>
      throw UnimplementedError('prefs.get not yet implemented');

  /// Replaces the set of advertised subnet routes.
  Future<TailscalePrefs> advertiseRoutes(List<String> cidrs) =>
      throw UnimplementedError('prefs.advertiseRoutes not yet implemented');

  /// Enables or disables accepting routes advertised by other nodes.
  Future<TailscalePrefs> setAcceptRoutes(bool enabled) =>
      throw UnimplementedError('prefs.setAcceptRoutes not yet implemented');

  /// Enables or disables "shields up" (reject all inbound connections).
  Future<TailscalePrefs> setShieldsUp(bool enabled) =>
      throw UnimplementedError('prefs.setShieldsUp not yet implemented');

  /// Enables or disables auto-updating the embedded runtime.
  Future<TailscalePrefs> setAutoUpdate(bool enabled) =>
      throw UnimplementedError('prefs.setAutoUpdate not yet implemented');

  /// Applies a [MaskedPrefs] atomically. Fields set on the mask are
  /// updated; fields left null are unchanged.
  Future<TailscalePrefs> updateMasked(MaskedPrefs mask) =>
      throw UnimplementedError('prefs.updateMasked not yet implemented');
}
