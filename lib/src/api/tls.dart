import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../errors.dart';

typedef TlsBindFn = Future<int> Function(int tailnetPort, int loopbackPort);
typedef TlsUnbindFn = Future<void> Function(int loopbackPort);
typedef TlsDomainsFn = Future<List<String>> Function();

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
abstract class Tls {
  /// Accepts inbound HTTPS connections on the tailnet. TLS is
  /// terminated inside the embedded Go runtime using the
  /// auto-provisioned Let's Encrypt cert, so handlers receive
  /// plaintext bytes via a standard `dart:io` [ServerSocket]. Wraps
  /// `tsnet.Server.ListenTLS`.
  ///
  /// [port] is the tailnet port to bind — pass `0` to request an
  /// ephemeral port, then read it back from [ServerSocket.port].
  ///
  /// Cert + private key stay inside the Go runtime, managed by the
  /// embedded cert refresher; Dart never sees key material. See
  /// `docs/api-roadmap.md` for the design rationale behind Go-side
  /// termination.
  ///
  /// Implementation: Dart owns an ephemeral 127.0.0.1 [ServerSocket];
  /// the Go side runs `s.ListenTLS("tcp", ":$port")` and for each
  /// accepted tailnet conn performs the TLS handshake then dials the
  /// loopback. The plaintext stream is piped end-to-end. Closing the
  /// returned [ServerSocket] tears down the tailnet listener.
  ///
  /// Note on co-residency: no per-connection auth on the loopback
  /// side. Co-resident processes could connect to the ephemeral
  /// loopback port and appear to be a remote peer. If that matters
  /// for your threat model, add an application-level handshake.
  ///
  /// Throws [TailscaleTlsException] on setup failure — most notably
  /// when MagicDNS or HTTPS is disabled on the tailnet.
  Future<ServerSocket> bind(int port);

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
Tls createTls({
  required TlsBindFn bindFn,
  required TlsUnbindFn unbindFn,
  required TlsDomainsFn domainsFn,
}) =>
    _Tls(bindFn, unbindFn, domainsFn);

final class _Tls implements Tls {
  _Tls(this._bind, this._unbind, this._domains);

  final TlsBindFn _bind;
  final TlsUnbindFn _unbind;
  final TlsDomainsFn _domains;

  @override
  Future<ServerSocket> bind(int port) async {
    final loopback = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final tailnetPort = await _bind(port, loopback.port);
      return _UnbindingServerSocket(
        loopback,
        tailnetPort,
        () => _unbind(loopback.port),
      );
    } catch (e) {
      await loopback.close();
      if (e is TailscaleException) rethrow;
      throw TailscaleTlsException(
        'tls.bind failed for tailnet port $port',
        cause: e,
      );
    }
  }

  @override
  Future<List<String>> domains() => _domains();
}

/// `ServerSocket` delegate that surfaces the tailnet port as
/// [ServerSocket.port] and fires an unbind hook after `close()` so the
/// Go-side tailnet listener tears down with the caller's handle.
class _UnbindingServerSocket extends StreamView<Socket>
    implements ServerSocket {
  _UnbindingServerSocket(this._delegate, this._tailnetPort, this._onClose)
      : super(_delegate);

  final ServerSocket _delegate;
  final int _tailnetPort;
  final Future<void> Function() _onClose;

  @override
  InternetAddress get address => _delegate.address;

  @override
  int get port => _tailnetPort;

  @override
  Future<ServerSocket> close() async {
    await _delegate.close();
    try {
      await _onClose();
    } catch (_) {}
    return this;
  }
}
