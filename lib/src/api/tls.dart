import 'dart:io';

import 'package:meta/meta.dart';

/// TLS-terminated listener with auto-provisioned cert from the control plane.
///
/// Reached via [Tailscale.tls]. Requires the tailnet operator to have
/// enabled MagicDNS + HTTPS in the admin panel; [bind] will fail with
/// a clear error if those are off. Use [domains] as a preflight to
/// check.
class Tls {
  /// Library-internal. Reach via `Tailscale.instance.tls`.
  @internal
  const Tls.internal();

  /// Binds a TLS listener on the tailnet. Wraps
  /// `tsnet.Server.ListenTLS`.
  ///
  /// The returned [SecureServerSocket] decrypts incoming traffic
  /// server-side; handlers see plaintext bytes.
  Future<SecureServerSocket> bind(int port) =>
      throw UnimplementedError('tls.bind not yet implemented');

  /// Subject Alternative Names present in the auto-provisioned certificate.
  ///
  /// Empty when MagicDNS or HTTPS is disabled on the tailnet.
  Future<List<String>> domains() =>
      throw UnimplementedError('tls.domains not yet implemented');
}
