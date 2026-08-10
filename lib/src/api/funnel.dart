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
/// Upstream Funnel visibility is scoped to the whole MagicDNS host and port,
/// not one path. Enabling Funnel on a port can make every ServeConfig handler
/// on that port publicly reachable. Prefer a dedicated public port or
/// authenticate every handler sharing it.
///
/// Serve and Funnel are two visibility modes of one upstream ServeConfig
/// publication authority. Publishing Funnel at the same port and path as an
/// existing Serve mapping replaces that mapping; it does not create an
/// independent listener or package reverse proxy.
///
/// The ServeConfig implementation is currently qualified only on
/// desktop/server platforms. Do not infer iOS or Android support until the
/// real-device HTTPS and persistent-sidecar inventory receipts pass.
///
/// Unlike [Serve.forward], public Funnel requests do not include Tailscale
/// identity headers. Authenticate public callers at the forwarded service layer
/// if the endpoint is not intentionally anonymous.
///
/// Funnel publications are process-scoped in this package. Close returned
/// handles explicitly; `Tailscale.down()` also clears package-created
/// publications best-effort before closing the embedded node.
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
  ///
  /// Funnel visibility applies to all handlers on [publicPort], even when this
  /// call mounts only one [path].
  Future<TailscalePublishedService> forward({
    required int localPort,
    int publicPort = 443,
    String localAddress = '127.0.0.1',
    String path = '/',
  });

  /// Removes a Funnel publication for [publicPort] and [path].
  ///
  /// Idempotent: clearing an absent mapping succeeds. Funnel and [Serve] share
  /// one mapping namespace, so this coordinate clear removes the current
  /// handler at [publicPort] and [path] and disables Funnel visibility for the
  /// host and port. Prefer the exact handle's
  /// [TailscalePublishedService.close] when replacements can race: a stale
  /// handle cannot remove its successor.
  Future<void> clear({int publicPort = 443, String path = '/'});
}

/// Library-internal factory. Reach via `Tailscale.instance.funnel`.
@internal
Funnel createFunnel({
  required ServeForwardFn forwardFn,
  required ServeClearFn clearFn,
  required ServeCloseFn closeFn,
}) => _Funnel(forwardFn: forwardFn, clearFn: clearFn, closeFn: closeFn);

final class _Funnel implements Funnel {
  _Funnel({
    required ServeForwardFn forwardFn,
    required ServeClearFn clearFn,
    required ServeCloseFn closeFn,
  }) : _forward = forwardFn,
       _clear = clearFn,
       _close = closeFn;

  final ServeForwardFn _forward;
  final ServeClearFn _clear;
  final ServeCloseFn _close;

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
        closeFn: _close,
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
