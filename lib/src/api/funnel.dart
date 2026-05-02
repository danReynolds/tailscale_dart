import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'serve.dart';

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
/// Funnel publications are process-scoped in this package. Close returned
/// handles explicitly; `Tailscale.down()` also tears down package-created
/// Funnel listeners and clears their Funnel config best-effort.
abstract class Funnel {
  /// Publishes `http://[localAddress]:[localPort]` on the public internet.
  ///
  /// [publicPort] defaults to 443. Tailscale currently allows Funnel only on
  /// policy-approved ports; unsupported ports throw [TailscaleFunnelException]
  /// with a structured error code where the native runtime can classify it.
  ///
  /// Bind the local service to `127.0.0.1` unless you intentionally want other
  /// host-local processes or interfaces to reach it directly.
  Future<TailscalePublishedService> forward({
    required int localPort,
    int publicPort = 443,
    String localAddress = '127.0.0.1',
    String path = '/',
  });

  /// Removes a Funnel publication for [publicPort] and [path].
  ///
  /// Idempotent: clearing an absent mapping succeeds. This removes the
  /// underlying Serve path as well; use [Serve.forward] when you want tailnet-
  /// only publication.
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
    final normalizedPath = _normalizePath(path);
    final normalizedAddress = _normalizeLocalAddress(localAddress);
    _validatePort(publicPort, 'publicPort');
    _validatePort(localPort, 'localPort');

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
    final normalizedPath = _normalizePath(path);
    _validatePort(publicPort, 'publicPort');
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

int _validatePort(int port, String name) {
  if (port < 1 || port > 65535) {
    throw RangeError.range(port, 1, 65535, name);
  }
  return port;
}

String _normalizeLocalAddress(String localAddress) {
  final trimmed = localAddress.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(
      localAddress,
      'localAddress',
      'must not be empty',
    );
  }
  return trimmed;
}

String _normalizePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '/';
  if (!trimmed.startsWith('/')) {
    throw ArgumentError.value(path, 'path', 'must start with /');
  }
  if (trimmed.contains('?') || trimmed.contains('#')) {
    throw ArgumentError.value(
      path,
      'path',
      'must not include query or fragment',
    );
  }
  return trimmed;
}
