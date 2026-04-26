import 'dart:io';

import 'package:meta/meta.dart';

typedef TlsDomainsFn = Future<List<String>> Function();

/// TLS-terminated listener for this node, with a cert auto-provisioned
/// from Let's Encrypt by the control plane. Nodes on the tailnet reach
/// the endpoint at `https://<node>.<tailnet>.ts.net` with no manual
/// cert wrangling.
///
/// Reached via [Tailscale.tls]. Requires the tailnet operator to have
/// enabled [MagicDNS](https://tailscale.com/kb/1081/magicdns) **and**
/// [HTTPS](https://tailscale.com/kb/1153/enabling-https) in the admin
/// panel; [bind] will fail with a clear error if either is off. Use
/// [domains] as a preflight to check.
abstract class Tls {
  /// Binds a TLS listener on the tailnet. Wraps
  /// `tsnet.Server.ListenTLS`.
  ///
  /// The returned [SecureServerSocket] decrypts incoming traffic
  /// server-side; handlers see plaintext bytes. Cert is renewed
  /// automatically by the embedded runtime before expiry.
  Future<SecureServerSocket> bind(int port);

  /// Subject Alternative Names present in the auto-provisioned certificate
  /// — typically `<node>.<tailnet>.ts.net`.
  ///
  /// Empty when [MagicDNS](https://tailscale.com/kb/1081/magicdns) or
  /// [HTTPS](https://tailscale.com/kb/1153/enabling-https) is disabled
  /// on the tailnet.
  Future<List<String>> domains();
}

/// Library-internal factory. Reach via `Tailscale.instance.tls`.
@internal
Tls createTls({required TlsDomainsFn domainsFn}) => _Tls(domainsFn);

final class _Tls implements Tls {
  _Tls(this._domains);

  final TlsDomainsFn _domains;

  @override
  Future<SecureServerSocket> bind(int port) =>
      throw UnimplementedError('tls.bind not yet implemented');

  @override
  Future<List<String>> domains() => _domains();
}
