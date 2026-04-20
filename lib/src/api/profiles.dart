import 'package:meta/meta.dart';

/// A saved login profile — one per account/tailnet stored on this node.

@immutable
class LoginProfile {
  const LoginProfile({
    required this.id,
    required this.userLoginName,
    required this.tailnetName,
  });

  /// Stable opaque identifier used with [Profiles.switchTo] / [Profiles.delete].
  final String id;

  /// Login email or user identifier.
  final String userLoginName;

  /// Tailnet this profile belongs to (e.g. `example.com`).
  final String tailnetName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginProfile &&
          id == other.id &&
          userLoginName == other.userLoginName &&
          tailnetName == other.tailnetName;

  @override
  int get hashCode => Object.hash(id, userLoginName, tailnetName);

  @override
  String toString() => 'LoginProfile(id: $id, userLoginName: $userLoginName, '
      'tailnetName: $tailnetName)';
}

/// Multi-account / multi-tailnet support: one node with several saved
/// login profiles. Switching changes which tailnet this node is a
/// member of without re-authenticating from scratch. Useful for a
/// single app that needs to operate in both a personal and a work
/// tailnet, or dev vs prod.
///
/// Mirrors the profile-management surface of the `tailscale` CLI —
/// see <https://tailscale.com/kb/1331/login-profiles> for the
/// end-user-facing concept.
///
/// Reached via [Tailscale.profiles].
class Profiles {
  /// Singleton namespace instance. Reach via `Tailscale.instance.profiles`.
  static const instance = Profiles._();

  const Profiles._();

  /// The currently active profile, or null if no profile is active on
  /// this node (e.g. the node has never logged in).
  Future<LoginProfile?> current() =>
      throw UnimplementedError('profiles.current not yet implemented');

  /// All profiles saved on this node.
  Future<List<LoginProfile>> list() =>
      throw UnimplementedError('profiles.list not yet implemented');

  /// Switches to [profile]. The engine disconnects from the current
  /// tailnet and connects with the target profile's credentials.
  ///
  /// Prefer this over [switchToId] — passing a [LoginProfile] you got
  /// from [list] catches stale IDs at the type level.
  Future<void> switchTo(LoginProfile profile) => switchToId(profile.id);

  /// Escape hatch for switching by stable profile ID — useful when the
  /// caller has persisted an ID across sessions and doesn't have the
  /// full [LoginProfile] handy.
  Future<void> switchToId(String profileId) =>
      throw UnimplementedError('profiles.switchToId not yet implemented');

  /// Removes a profile and its persisted credentials.
  ///
  /// Prefer this over [deleteById] — passing a [LoginProfile] you got
  /// from [list] catches stale IDs at the type level.
  Future<void> delete(LoginProfile profile) => deleteById(profile.id);

  /// Escape hatch for deleting by stable profile ID.
  Future<void> deleteById(String profileId) =>
      throw UnimplementedError('profiles.deleteById not yet implemented');

  /// Creates an empty profile slot. The next [Tailscale.up] with a fresh
  /// authkey registers a new node under this slot without touching other
  /// profiles.
  Future<void> newEmpty() =>
      throw UnimplementedError('profiles.newEmpty not yet implemented');
}
