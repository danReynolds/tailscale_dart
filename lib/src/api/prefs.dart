import 'package:meta/meta.dart';

import '../_equality.dart';

typedef PrefsGetFn = Future<TailscalePrefs> Function();
typedef PrefsUpdateFn = Future<TailscalePrefs> Function(PrefsUpdate update);

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
    this.autoExitNode = false,
    this.exitNodeId,
  });

  /// CIDRs this node advertises as a subnet router. Requires operator
  /// approval in the admin panel before other nodes will pick them up.
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

  /// Whether automatic exit-node selection is enabled.
  ///
  /// When true, tailscaled may select or re-select an eligible exit node based
  /// on current policy and path quality. Use [ExitNode.current] to inspect the
  /// node currently selected by the runtime.
  final bool autoExitNode;

  /// Stable node ID currently in use as an exit node, or null if none.
  final String? exitNodeId;

  /// Parses the JSON shape returned by the native LocalAPI wrapper.
  factory TailscalePrefs.fromJson(Map<String, dynamic> json) => TailscalePrefs(
    advertisedRoutes:
        (json['advertisedRoutes'] as List?)?.cast<String>() ?? const [],
    acceptRoutes: json['acceptRoutes'] as bool? ?? false,
    shieldsUp: json['shieldsUp'] as bool? ?? false,
    advertisedTags:
        (json['advertisedTags'] as List?)?.cast<String>() ?? const [],
    wantRunning: json['wantRunning'] as bool? ?? false,
    autoUpdate: json['autoUpdate'] as bool? ?? false,
    hostname: json['hostname'] as String? ?? '',
    autoExitNode: json['autoExitNode'] as bool? ?? false,
    exitNodeId: json['exitNodeId'] as String?,
  );

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
          autoExitNode == other.autoExitNode &&
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
    autoExitNode,
    exitNodeId,
  );

  @override
  String toString() =>
      'TailscalePrefs(advertisedRoutes: $advertisedRoutes, '
      'acceptRoutes: $acceptRoutes, shieldsUp: $shieldsUp, '
      'advertisedTags: $advertisedTags, wantRunning: $wantRunning, '
      'autoUpdate: $autoUpdate, hostname: $hostname, '
      'autoExitNode: $autoExitNode, '
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
  String toString() =>
      'PrefsUpdate(advertisedRoutes: $advertisedRoutes, '
      'acceptRoutes: $acceptRoutes, shieldsUp: $shieldsUp, '
      'advertisedTags: $advertisedTags, wantRunning: $wantRunning, '
      'autoUpdate: $autoUpdate, hostname: $hostname, '
      'exitNodeId: $exitNodeId)';

  /// Encodes only fields that should be modified.
  Map<String, Object?> toJson() => {
    if (advertisedRoutes != null) 'advertisedRoutes': advertisedRoutes,
    if (acceptRoutes != null) 'acceptRoutes': acceptRoutes,
    if (shieldsUp != null) 'shieldsUp': shieldsUp,
    if (advertisedTags != null) 'advertisedTags': advertisedTags,
    if (wantRunning != null) 'wantRunning': wantRunning,
    if (autoUpdate != null) 'autoUpdate': autoUpdate,
    if (hostname != null) 'hostname': hostname,
    if (exitNodeId != null) 'exitNodeId': exitNodeId,
  };
}

/// Low-level escape hatch for preferences that don't have a dedicated
/// namespace — subnet routes, Shields Up, auto-update opt-in, tags, etc.
///
/// Reached via [Tailscale.prefs]. For common single-field changes prefer
/// the named setters; for atomic multi-field edits use [updateMasked].
abstract class Prefs {
  /// Current preferences snapshot.
  Future<TailscalePrefs> get();

  /// Replaces the set of CIDRs this node advertises as a subnet router.
  /// See <https://tailscale.com/kb/1019/subnets>. Still requires admin
  /// approval of each route in the control plane before other nodes use it.
  Future<TailscalePrefs> setAdvertisedRoutes(List<String> cidrs);

  /// Accept subnet routes advertised by other nodes on the tailnet.
  Future<TailscalePrefs> setAcceptRoutes(bool enabled);

  /// Reject all inbound connections when true. See
  /// <https://tailscale.com/kb/1072/client-preferences#block-incoming-connections>.
  Future<TailscalePrefs> setShieldsUp(bool enabled);

  /// Opt in or out of automatic tsnet version updates from the control
  /// plane.
  Future<TailscalePrefs> setAutoUpdate(bool enabled);

  /// Replaces the set of [ACL tags](https://tailscale.com/kb/1068/tags)
  /// this node advertises when registering.
  Future<TailscalePrefs> setAdvertisedTags(List<String> tags);

  /// Applies a [PrefsUpdate] atomically. Fields set on the update are
  /// written; fields left null are unchanged.
  Future<TailscalePrefs> updateMasked(PrefsUpdate update);
}

/// Library-internal factory. Reach via `Tailscale.instance.prefs`.
@internal
Prefs createPrefs({
  required PrefsGetFn getFn,
  required PrefsUpdateFn updateFn,
}) => _Prefs(getFn: getFn, updateFn: updateFn);

final class _Prefs implements Prefs {
  _Prefs({required PrefsGetFn getFn, required PrefsUpdateFn updateFn})
    : _get = getFn,
      _update = updateFn;

  final PrefsGetFn _get;
  final PrefsUpdateFn _update;

  @override
  Future<TailscalePrefs> get() => _get();

  @override
  Future<TailscalePrefs> setAdvertisedRoutes(List<String> cidrs) =>
      updateMasked(PrefsUpdate(advertisedRoutes: List.unmodifiable(cidrs)));

  @override
  Future<TailscalePrefs> setAcceptRoutes(bool enabled) =>
      updateMasked(PrefsUpdate(acceptRoutes: enabled));

  @override
  Future<TailscalePrefs> setShieldsUp(bool enabled) =>
      updateMasked(PrefsUpdate(shieldsUp: enabled));

  @override
  Future<TailscalePrefs> setAutoUpdate(bool enabled) =>
      updateMasked(PrefsUpdate(autoUpdate: enabled));

  @override
  Future<TailscalePrefs> setAdvertisedTags(List<String> tags) =>
      updateMasked(PrefsUpdate(advertisedTags: List.unmodifiable(tags)));

  @override
  Future<TailscalePrefs> updateMasked(PrefsUpdate update) => _update(update);
}
