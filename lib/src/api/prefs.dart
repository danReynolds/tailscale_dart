import 'package:meta/meta.dart';

import '../_equality.dart';

/// Node preferences. Mirrors a subset of `ipn.Prefs` on the Go side.
///
/// Fields cover the long tail of tsnet configuration that doesn't warrant
/// its own top-level namespace. Use [Prefs.get] to read; use the named
/// setters on [Prefs] (`setAdvertisedRoutes(...)`, `setShieldsUp(true)`,
/// etc.) for common single-field changes, or [Prefs.updateMasked] for
/// atomic multi-field edits.
@immutable
class TailscalePrefs {
  const TailscalePrefs({
    required this.advertisedRoutes,
    required this.acceptRoutes,
    required this.shieldsUp,
    required this.advertisedTags,
    required this.wantRunning,
    required this.autoUpdate,
    required this.hostname,
    this.exitNodeId,
  });

  /// CIDRs this node advertises as a subnet router. Requires operator
  /// approval in the admin panel before peers will pick them up.
  /// See <https://tailscale.com/kb/1019/subnets>.
  final List<String> advertisedRoutes;

  /// Accept subnet routes advertised by other nodes on the tailnet.
  final bool acceptRoutes;

  /// When true, reject all inbound connections to this node — useful
  /// for locked-down laptops / servers that should only initiate.
  /// See <https://tailscale.com/kb/1072/client-preferences#block-incoming-connections>.
  final bool shieldsUp;

  /// [ACL tags](https://tailscale.com/kb/1068/tags) to advertise when
  /// registering the node. Tags let authz decisions reference this
  /// node by role (e.g. `tag:server`) rather than by owner.
  final List<String> advertisedTags;

  /// Whether the engine should be connected (i.e. not manually paused).
  final bool wantRunning;

  /// Auto-update the underlying tsnet when a newer version is released.
  final bool autoUpdate;

  /// The tailnet-visible hostname for this node.
  final String hostname;

  /// Stable node ID currently in use as an exit node, or null if none.
  final String? exitNodeId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscalePrefs &&
          listEquals(advertisedRoutes, other.advertisedRoutes) &&
          acceptRoutes == other.acceptRoutes &&
          shieldsUp == other.shieldsUp &&
          listEquals(advertisedTags, other.advertisedTags) &&
          wantRunning == other.wantRunning &&
          autoUpdate == other.autoUpdate &&
          hostname == other.hostname &&
          exitNodeId == other.exitNodeId;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(advertisedRoutes),
        acceptRoutes,
        shieldsUp,
        Object.hashAll(advertisedTags),
        wantRunning,
        autoUpdate,
        hostname,
        exitNodeId,
      );

  @override
  String toString() => 'TailscalePrefs(advertisedRoutes: $advertisedRoutes, '
      'acceptRoutes: $acceptRoutes, shieldsUp: $shieldsUp, '
      'advertisedTags: $advertisedTags, wantRunning: $wantRunning, '
      'autoUpdate: $autoUpdate, hostname: $hostname, '
      'exitNodeId: $exitNodeId)';
}

/// A multi-field atomic update to [TailscalePrefs]. Only fields set on
/// this object are modified; unset fields are left alone.
///
/// Mirrors `ipn.MaskedPrefs` on the Go side. Renamed to [PrefsUpdate] in
/// this library because the "masked" terminology is a Go-isms that does
/// not translate — in Dart, the builder-plus-mask pattern is expressed
/// naturally as an object whose fields default to null.
@immutable
class PrefsUpdate {
  const PrefsUpdate({
    this.advertisedRoutes,
    this.acceptRoutes,
    this.shieldsUp,
    this.advertisedTags,
    this.wantRunning,
    this.autoUpdate,
    this.hostname,
    this.exitNodeId,
  });

  final List<String>? advertisedRoutes;
  final bool? acceptRoutes;
  final bool? shieldsUp;
  final List<String>? advertisedTags;
  final bool? wantRunning;
  final bool? autoUpdate;
  final String? hostname;

  /// Pass empty string to clear the current exit node; `null` leaves
  /// unchanged (Dart's single-null problem; use named setters on
  /// [Prefs] or [ExitNode] for clarity).
  final String? exitNodeId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrefsUpdate &&
          listEquals(advertisedRoutes, other.advertisedRoutes) &&
          acceptRoutes == other.acceptRoutes &&
          shieldsUp == other.shieldsUp &&
          listEquals(advertisedTags, other.advertisedTags) &&
          wantRunning == other.wantRunning &&
          autoUpdate == other.autoUpdate &&
          hostname == other.hostname &&
          exitNodeId == other.exitNodeId;

  @override
  int get hashCode => Object.hash(
        advertisedRoutes == null ? null : Object.hashAll(advertisedRoutes!),
        acceptRoutes,
        shieldsUp,
        advertisedTags == null ? null : Object.hashAll(advertisedTags!),
        wantRunning,
        autoUpdate,
        hostname,
        exitNodeId,
      );

  @override
  String toString() => 'PrefsUpdate(advertisedRoutes: $advertisedRoutes, '
      'acceptRoutes: $acceptRoutes, shieldsUp: $shieldsUp, '
      'advertisedTags: $advertisedTags, wantRunning: $wantRunning, '
      'autoUpdate: $autoUpdate, hostname: $hostname, '
      'exitNodeId: $exitNodeId)';
}

/// Low-level escape hatch for preferences that don't have a dedicated
/// namespace — subnet routes, Shields Up, auto-update opt-in, tags, etc.
///
/// Reached via [Tailscale.prefs]. For common single-field changes prefer
/// the named setters; for atomic multi-field edits use [updateMasked].
class Prefs {
  /// Singleton namespace instance. Reach via `Tailscale.instance.prefs`.
  static const instance = Prefs._();

  const Prefs._();

  /// Current preferences snapshot.
  Future<TailscalePrefs> get() =>
      throw UnimplementedError('prefs.get not yet implemented');

  /// Replaces the set of CIDRs this node advertises as a subnet router.
  /// See <https://tailscale.com/kb/1019/subnets>. Still requires admin
  /// approval of each route in the control plane before peers use it.
  Future<TailscalePrefs> setAdvertisedRoutes(List<String> cidrs) =>
      throw UnimplementedError('prefs.setAdvertisedRoutes not yet implemented');

  /// Accept subnet routes advertised by other nodes on the tailnet.
  Future<TailscalePrefs> setAcceptRoutes(bool enabled) =>
      throw UnimplementedError('prefs.setAcceptRoutes not yet implemented');

  /// Reject all inbound connections when true. See
  /// <https://tailscale.com/kb/1072/client-preferences#block-incoming-connections>.
  Future<TailscalePrefs> setShieldsUp(bool enabled) =>
      throw UnimplementedError('prefs.setShieldsUp not yet implemented');

  /// Opt in or out of automatic tsnet version updates from the control
  /// plane.
  Future<TailscalePrefs> setAutoUpdate(bool enabled) =>
      throw UnimplementedError('prefs.setAutoUpdate not yet implemented');

  /// Replaces the set of [ACL tags](https://tailscale.com/kb/1068/tags)
  /// this node advertises when registering.
  Future<TailscalePrefs> setAdvertisedTags(List<String> tags) =>
      throw UnimplementedError('prefs.setAdvertisedTags not yet implemented');

  /// Applies a [PrefsUpdate] atomically. Fields set on the update are
  /// written; fields left null are unchanged.
  Future<TailscalePrefs> updateMasked(PrefsUpdate update) =>
      throw UnimplementedError('prefs.updateMasked not yet implemented');
}
