import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'serve.dart';
import 'serve_validation.dart';

/// Public-internet publication for an existing local HTTP service.
///
/// Reached via [Tailscale.funnel]. Funnel is the public counterpart to
/// [Serve.forward]: Tailscale publishes this node's MagicDNS HTTPS name to the
/// open internet, then proxies requests through the tailnet to the local
/// loopback HTTP service you own.
///
/// Requirements are controlled by the tailnet operator: HTTPS must be enabled,
/// the node must have the Funnel node attribute, and the requested port must be
/// allowed by policy.
///
/// Unlike [Serve.forward], public Funnel requests do not include Tailscale
/// identity headers. Authenticate public callers at the forwarded service layer
/// if the endpoint is not intentionally anonymous.
///
/// Funnel publications are process-scoped in this package. Close returned
/// handles explicitly; `Tailscale.down()` also tears down package-created
/// Funnel listeners and clears their Funnel config best-effort.
abstract class Funnel {
  /// Publishes `http://[localAddress]:[localPort]` on the public internet.
  ///
  /// [publicPort] defaults to 443. Tailscale currently allows Funnel only on
  /// policy-approved ports (commonly 443, 8443, and 10000; see
  /// https://tailscale.com/docs/features/tailscale-funnel); unsupported ports throw
  /// [TailscaleFunnelException] with a structured error code where the native
  /// runtime can classify it.
  ///
  /// [localAddress] must be loopback (`127.0.0.1`, `::1`, or `localhost`).
  /// This prevents accidentally publishing arbitrary LAN or metadata-service
  /// endpoints to the public internet.
  Future<TailscalePublishedService> forward({
    required int localPort,
    int publicPort = 443,
    String localAddress = '127.0.0.1',
    String path = '/',
  });

  /// Removes a Funnel publication for [publicPort] and [path].
  ///
  /// Idempotent: clearing an absent mapping succeeds. Funnel publications are
  /// independent of [Serve] — this clears only the Funnel mapping and does not
  /// touch any Serve path for the same port. Use [Serve] for tailnet-only
  /// publication.
  Future<void> clear({int publicPort = 443, String path = '/'});
}

/// Library-internal factory. Reach via `Tailscale.instance.funnel`.
@internal
Funnel createFunnel({
  required ServeForwardFn forwardFn,
  required ServeClearFn clearFn,
}) => _Funnel(forwardFn: forwardFn, clearFn: clearFn);

final class _Funnel implements Funnel {
  _Funnel({required ServeForwardFn forwardFn, required ServeClearFn clearFn})
    : _forward = forwardFn,
      _clear = clearFn;

  final ServeForwardFn _forward;
  final ServeClearFn _clear;

  @override
  Future<TailscalePublishedService> forward({
    required int localPort,
    int publicPort = 443,
    String localAddress = '127.0.0.1',
    String path = '/',
  }) async {
    if (Platform.isWindows) {
      throw const TailscaleFunnelException('Windows is not supported.');
    }
    final normalizedPath = normalizeServePath(path);
    final normalizedAddress = normalizeServeLocalAddress(localAddress);
    validateServePort(publicPort, 'publicPort');
    validateServePort(localPort, 'localPort');

    try {
      final published = await _forward(
        tailnetPort: publicPort,
        localPort: localPort,
        localAddress: normalizedAddress,
        path: normalizedPath,
        https: true,
        funnel: true,
      );
      return createPublishedServiceForFunnel(
        published: published,
        closeFn: () => clear(publicPort: published.port, path: published.path),
      );
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleFunnelException(
        'funnel.forward failed for public port $publicPort',
        cause: e,
      );
    }
  }

  @override
  Future<void> clear({int publicPort = 443, String path = '/'}) async {
    if (Platform.isWindows) {
      throw const TailscaleFunnelException('Windows is not supported.');
    }
    final normalizedPath = normalizeServePath(path);
    validateServePort(publicPort, 'publicPort');
    try {
      await _clear(tailnetPort: publicPort, path: normalizedPath, funnel: true);
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleFunnelException(
        'funnel.clear failed for public port $publicPort',
        cause: e,
      );
    }
  }
}
