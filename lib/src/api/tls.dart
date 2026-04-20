import 'dart:io';

import 'package:meta/meta.dart';

/// TLS-terminated listener for this node, with a cert auto-provisioned
/// from Let's Encrypt by the control plane. Peers on the tailnet reach
/// the endpoint at `https://<node>.<tailnet>.ts.net` with no manual
/// cert wrangling.
///
/// Reached via [Tailscale.tls]. Requires the tailnet operator to have
/// enabled [MagicDNS](https://tailscale.com/kb/1081/magicdns) **and**
/// [HTTPS](https://tailscale.com/kb/1153/enabling-https) in the admin
/// panel; [bind] will fail with a clear error if either is off. Use
/// [domains] as a preflight to check.
class Tls {
  /// Library-internal. Reach via `Tailscale.instance.tls`.
  @internal
  const Tls.internal();

  /// Binds a TLS listener on the tailnet. Wraps
  /// `tsnet.Server.ListenTLS`.
  ///
  /// The returned [SecureServerSocket] decrypts incoming traffic
  /// server-side; handlers see plaintext bytes. Cert is renewed
  /// automatically by the embedded runtime before expiry.
  Future<SecureServerSocket> bind(int port) =>
      throw UnimplementedError('tls.bind not yet implemented');

  /// Subject Alternative Names present in the auto-provisioned certificate
  /// — typically `<node>.<tailnet>.ts.net`.
  ///
  /// Empty when [MagicDNS](https://tailscale.com/kb/1081/magicdns) or
  /// [HTTPS](https://tailscale.com/kb/1153/enabling-https) is disabled
  /// on the tailnet.
  Future<List<String>> domains() =>
      throw UnimplementedError('tls.domains not yet implemented');
}
