/// A saved login profile — one per account/tailnet stored on this node.
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
}

/// Multi-account / multi-tailnet support: one node, several identities.
///
/// Reached via [Tailscale.profiles]. Useful for a single app that needs to
/// operate in both a personal and a work tailnet, or dev vs. prod.
class Profiles {
  const Profiles();

  /// The currently active profile.
  Future<LoginProfile> current() =>
      throw UnimplementedError('profiles.current not yet implemented');

  /// All profiles saved on this node.
  Future<List<LoginProfile>> list() =>
      throw UnimplementedError('profiles.list not yet implemented');

  /// Switches to [profileId]. The engine disconnects from the current
  /// tailnet and connects with the target profile's credentials.
  Future<void> switchTo(String profileId) =>
      throw UnimplementedError('profiles.switchTo not yet implemented');

  /// Removes a profile and its persisted credentials.
  Future<void> delete(String profileId) =>
      throw UnimplementedError('profiles.delete not yet implemented');

  /// Creates an empty profile slot. The next [Tailscale.up] with a fresh
  /// authkey registers a new node under this slot without touching other
  /// profiles.
  Future<void> newEmpty() =>
      throw UnimplementedError('profiles.newEmpty not yet implemented');
}
