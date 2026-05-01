import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'connection.dart';

typedef TlsListenFn =
    Future<({int listenerId, TailscaleEndpoint local})> Function(
      int tailnetPort,
      String tailnetHost,
    );

typedef TlsCloseListenerFn = Future<void> Function(int listenerId);

typedef TlsDomainsFn = Future<List<String>> Function();

/// TLS-terminated listener for this node, with a cert auto-provisioned by
/// Tailscale for this tailnet.
///
/// Reached via [Tailscale.tls]. Requires the tailnet operator to have enabled
/// [MagicDNS](https://tailscale.com/kb/1081/magicdns) and
/// [HTTPS](https://tailscale.com/kb/1153/enabling-https). Use [domains] as a
/// preflight; an empty result means the tailnet cannot currently serve
/// auto-provisioned TLS certs.
abstract class Tls {
  /// Accepts inbound HTTPS/TLS connections on the tailnet.
  ///
  /// [port] is the tailnet port to bind. Pass `0` to request an ephemeral
  /// tailnet port, then read it from the returned [TailscaleListener.local].
  ///
  /// [address] restricts the listener to a specific tailnet IP of this node;
  /// leave null to accept on all tailnet IPs this node holds.
  ///
  /// Go terminates TLS using `tsnet.Server.ListenTLS`. Dart receives
  /// package-native plaintext [TailscaleConnection] objects, not
  /// `dart:io` sockets.
  Future<TailscaleListener> bind({required int port, String? address});

  /// Subject Alternative Names present in the auto-provisioned certificate —
  /// typically `<node>.<tailnet>.ts.net`.
  ///
  /// Empty when [MagicDNS](https://tailscale.com/kb/1081/magicdns) or
  /// [HTTPS](https://tailscale.com/kb/1153/enabling-https) is disabled on the
  /// tailnet.
  Future<List<String>> domains();
}

/// Library-internal factory. Reach via `Tailscale.instance.tls`.
@internal
Tls createTls({
  required TlsListenFn listenFn,
  required TlsCloseListenerFn closeListenerFn,
  required TlsDomainsFn domainsFn,
}) => _Tls(listenFn, closeListenerFn, domainsFn);

final class _Tls implements Tls {
  _Tls(this._listen, this._closeListener, this._domains);

  final TlsListenFn _listen;
  final TlsCloseListenerFn _closeListener;
  final TlsDomainsFn _domains;

  @override
  Future<TailscaleListener> bind({required int port, String? address}) async {
    if (Platform.isWindows) {
      throw const TailscaleTlsException('Windows is not supported.');
    }
    try {
      final (:listenerId, :local) = await _listen(port, address ?? '');
      return createFdTailscaleListener(
        listenerId: listenerId,
        local: local,
        closeFn: _closeListener,
      );
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleTlsException(
        'tls.bind failed for tailnet port $port',
        cause: e,
      );
    }
  }

  @override
  Future<List<String>> domains() async {
    try {
      return await _domains();
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleTlsException('tls.domains failed', cause: e);
    }
  }
}
