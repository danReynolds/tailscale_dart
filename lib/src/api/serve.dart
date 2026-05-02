import 'dart:io' show InternetAddress, Platform;

import 'package:meta/meta.dart';

import '../errors.dart';

typedef ServeForwardFn =
    Future<
      ({
        Uri url,
        int port,
        String localAddress,
        int localPort,
        String path,
        bool https,
        bool funnel,
      })
    >
    Function({
      required int tailnetPort,
      required int localPort,
      required String localAddress,
      required String path,
      required bool https,
      required bool funnel,
    });

typedef ServeClearFn =
    Future<void> Function({
      required int tailnetPort,
      required String path,
      required bool funnel,
    });

/// A Serve or Funnel publication that forwards inbound traffic to a local
/// loopback HTTP service.
///
/// This is a publication handle, not a socket. The local app owns the HTTP
/// server on [localAddress]:[localPort]; Tailscale owns the tailnet/public
/// listener and proxies requests to that local server.
///
/// Publications created by this package are process-scoped. Call [close] when
/// the publication should disappear; `Tailscale.down()` also removes
/// package-created publications best-effort before stopping the embedded node.
final class TailscalePublishedService {
  TailscalePublishedService._({
    required this.url,
    required this.port,
    required this.localAddress,
    required this.localPort,
    required this.path,
    required this.https,
    required this.funnel,
    required Future<void> Function() closeFn,
  }) : _closeFn = closeFn;

  /// URL where clients can reach the publication.
  ///
  /// For [Serve.forward], this is reachable inside the tailnet. For
  /// [Funnel.forward], this is reachable from the public internet if Funnel is
  /// enabled for the node and port.
  final Uri url;

  /// Published port on the node's MagicDNS name.
  ///
  /// For Serve this is a tailnet port. For Funnel this is the public Funnel
  /// port, typically 443.
  final int port;

  /// Local address that Tailscale proxies to. Defaults to `127.0.0.1`.
  final String localAddress;

  /// Local HTTP server port that Tailscale proxies to.
  final int localPort;

  /// Path prefix mounted on [url].
  final String path;

  /// Whether Tailscale terminates HTTPS before proxying to the local service.
  final bool https;

  /// Whether this publication is exposed through Tailscale Funnel.
  final bool funnel;

  final Future<void> Function() _closeFn;
  Future<void>? _closeFuture;

  /// Removes this publication from the embedded node.
  ///
  /// Idempotent for a given handle. If another caller has replaced the same
  /// path/port before this is called, the current mapping at that path is
  /// removed.
  Future<void> close() => _closeFuture ??= _closeFn();

  @override
  String toString() =>
      'TailscalePublishedService(url: $url, port: $port, local: '
      '$localAddress:$localPort, path: $path, funnel: $funnel)';
}

/// Tailnet publication for an existing local HTTP service.
///
/// Reached via [Tailscale.serve]. Use this when you already have a local HTTP
/// server (for example a Shelf app) bound to loopback and want Tailscale to
/// publish it on this node's MagicDNS name.
///
/// For in-process request handling without a local TCP listener, prefer
/// `Tailscale.http.bind(...)`; it is fd-backed and does not expose a loopback
/// port to other local processes.
///
/// `serve.forward` is process-scoped in this package, not a persistent
/// background `tailscale serve --bg` configuration surface. Close returned
/// handles explicitly; `Tailscale.down()` also removes package-created
/// publications best-effort.
abstract class Serve {
  /// Publishes `http://[localAddress]:[localPort]` inside the tailnet.
  ///
  /// [tailnetPort] is the port on this node's MagicDNS name. [https] defaults
  /// to true, so the tailnet URL is `https://<node>...` and Tailscale
  /// terminates TLS before forwarding plaintext HTTP to the local service.
  ///
  /// [localAddress] must be loopback (`127.0.0.1`, `::1`, or `localhost`).
  /// This prevents accidentally publishing arbitrary LAN or metadata-service
  /// endpoints through the tailnet.
  Future<TailscalePublishedService> forward({
    required int tailnetPort,
    required int localPort,
    String localAddress = '127.0.0.1',
    String path = '/',
    bool https = true,
  });

  /// Removes a tailnet Serve publication for [tailnetPort] and [path].
  ///
  /// Idempotent: clearing an absent mapping succeeds.
  Future<void> clear({required int tailnetPort, String path = '/'});
}

/// Library-internal factory. Reach via `Tailscale.instance.serve`.
@internal
Serve createServe({
  required ServeForwardFn forwardFn,
  required ServeClearFn clearFn,
}) => _Serve(forwardFn: forwardFn, clearFn: clearFn);

final class _Serve implements Serve {
  _Serve({required ServeForwardFn forwardFn, required ServeClearFn clearFn})
    : _forward = forwardFn,
      _clear = clearFn;

  final ServeForwardFn _forward;
  final ServeClearFn _clear;

  @override
  Future<TailscalePublishedService> forward({
    required int tailnetPort,
    required int localPort,
    String localAddress = '127.0.0.1',
    String path = '/',
    bool https = true,
  }) async {
    if (Platform.isWindows) {
      throw const TailscaleServeException('Windows is not supported.');
    }
    final normalizedPath = _normalizePath(path);
    final normalizedAddress = _normalizeLocalAddress(localAddress);
    _validatePort(tailnetPort, 'tailnetPort');
    _validatePort(localPort, 'localPort');

    try {
      final published = await _forward(
        tailnetPort: tailnetPort,
        localPort: localPort,
        localAddress: normalizedAddress,
        path: normalizedPath,
        https: https,
        funnel: false,
      );
      return _publicationFrom(
        published,
        closeFn: () => clear(tailnetPort: published.port, path: published.path),
      );
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleServeException(
        'serve.forward failed for tailnet port $tailnetPort',
        cause: e,
      );
    }
  }

  @override
  Future<void> clear({required int tailnetPort, String path = '/'}) async {
    if (Platform.isWindows) {
      throw const TailscaleServeException('Windows is not supported.');
    }
    final normalizedPath = _normalizePath(path);
    _validatePort(tailnetPort, 'tailnetPort');
    try {
      await _clear(
        tailnetPort: tailnetPort,
        path: normalizedPath,
        funnel: false,
      );
    } catch (e) {
      if (e is TailscaleException) rethrow;
      throw TailscaleServeException(
        'serve.clear failed for tailnet port $tailnetPort',
        cause: e,
      );
    }
  }
}

@internal
TailscalePublishedService createPublishedServiceForFunnel({
  required ({
    Uri url,
    int port,
    String localAddress,
    int localPort,
    String path,
    bool https,
    bool funnel,
  })
  published,
  required Future<void> Function() closeFn,
}) => _publicationFrom(published, closeFn: closeFn);

TailscalePublishedService _publicationFrom(
  ({
    Uri url,
    int port,
    String localAddress,
    int localPort,
    String path,
    bool https,
    bool funnel,
  })
  published, {
  required Future<void> Function() closeFn,
}) => TailscalePublishedService._(
  url: published.url,
  port: published.port,
  localAddress: published.localAddress,
  localPort: published.localPort,
  path: published.path,
  https: published.https,
  funnel: published.funnel,
  closeFn: closeFn,
);

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
  if (!_isLoopbackAddress(trimmed)) {
    throw ArgumentError.value(
      localAddress,
      'localAddress',
      'must be a loopback address such as 127.0.0.1, ::1, or localhost',
    );
  }
  return trimmed;
}

bool _isLoopbackAddress(String address) {
  if (address.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(address)?.isLoopback ?? false;
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
  if (_containsPathTraversal(trimmed)) {
    throw ArgumentError.value(
      path,
      'path',
      'must not include . or .. segments',
    );
  }
  return trimmed;
}

bool _containsPathTraversal(String path) {
  for (final segment in path.split('/')) {
    if (segment == '.' || segment == '..') return true;
  }
  return false;
}
