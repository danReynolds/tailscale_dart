import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'serve_validation.dart';

typedef ServeForwardResult = ({
  Uri url,
  int port,
  String localAddress,
  int localPort,
  String path,
  bool https,
  bool funnel,
  int generation,
  int mappingToken,
});

typedef ServeForwardFn =
    Future<ServeForwardResult> Function({
      required int tailnetPort,
      required int localPort,
      required String localAddress,
      required String path,
      required bool https,
      required bool funnel,
    });

typedef ServeCloseFn =
    Future<void> Function({
      required int tailnetPort,
      required String path,
      required bool funnel,
      required int generation,
      required int mappingToken,
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
  }) : _closeFn = closeFn {
    _publishedServiceFinalizer.attach(
      this,
      _PublishedServiceFinalizerToken(closeFn),
      detach: this,
    );
  }

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
  /// Idempotent for a given handle. This closes only the exact mapping created
  /// for this handle. Replaced mappings and mappings from a newer runtime are
  /// left untouched.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    late final Future<void> attempt;
    attempt = Future<void>.sync(_closeFn).then<void>(
      (_) {
        if (identical(_closeFuture, attempt)) {
          _publishedServiceFinalizer.detach(this);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        // Native retains exact ownership on a confirmed-not-applied failure.
        // Keep the GC fallback attached and let a later explicit close retry.
        // The identity check also closes the synchronous-throw assignment race.
        if (identical(_closeFuture, attempt)) {
          _closeFuture = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _closeFuture = attempt;
    return attempt;
  }

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
///
/// Requests from tailnet clients follow upstream Tailscale Serve behavior:
/// Tailscale forwards identity headers such as `Tailscale-User-Login`,
/// `Tailscale-User-Name`, and `Tailscale-User-Profile-Pic` to the loopback
/// backend. Public Funnel requests do not include those headers.
///
/// Funnel visibility is host:port-scoped upstream. Do not place a supposedly
/// private Serve path on a port that another mapping exposes through Funnel;
/// use a separate port or authenticate every handler on the shared port.
///
/// Mobile HTTPS publication is not currently a qualified support surface. Do
/// not infer iOS/Android support from desktop behavior; it remains gated on
/// real-device HTTPS and persistent-sidecar inventory receipts.
abstract class Serve {
  /// Publishes `http://[localAddress]:[localPort]` inside the tailnet.
  ///
  /// [tailnetPort] is the port on this node's MagicDNS name. [https] defaults
  /// to true, so the tailnet URL is `https://<node>...` and Tailscale
  /// terminates TLS before forwarding plaintext HTTP to the local service.
  /// On iOS and Android this HTTPS mode is currently unqualified and should not
  /// be presented as supported until the package's mobile receipt is published.
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
  required ServeCloseFn closeFn,
}) => _Serve(forwardFn: forwardFn, clearFn: clearFn, closeFn: closeFn);

final class _Serve implements Serve {
  _Serve({
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
    required int tailnetPort,
    required int localPort,
    String localAddress = '127.0.0.1',
    String path = '/',
    bool https = true,
  }) async {
    if (Platform.isWindows) {
      throw const TailscaleServeException('Windows is not supported.');
    }
    final normalizedPath = normalizeServePath(path);
    final normalizedAddress = normalizeServeLocalAddress(localAddress);
    validateServePort(tailnetPort, 'tailnetPort');
    validateServePort(localPort, 'localPort');

    try {
      final published = await _forward(
        tailnetPort: tailnetPort,
        localPort: localPort,
        localAddress: normalizedAddress,
        path: normalizedPath,
        https: https,
        funnel: false,
      );
      return _publicationFrom(published, closeFn: _close);
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
    final normalizedPath = normalizeServePath(path);
    validateServePort(tailnetPort, 'tailnetPort');
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
  required ServeForwardResult published,
  required ServeCloseFn closeFn,
}) => _publicationFrom(published, closeFn: closeFn);

TailscalePublishedService _publicationFrom(
  ServeForwardResult published, {
  required ServeCloseFn closeFn,
}) {
  if (published.generation <= 0 || published.mappingToken <= 0) {
    const message =
        'Native runtime returned a publication without an exact handle.';
    if (published.funnel) {
      throw const TailscaleFunnelException(
        message,
        code: TailscaleErrorCode.publicationCommitIndeterminate,
      );
    }
    throw const TailscaleServeException(
      message,
      code: TailscaleErrorCode.publicationCommitIndeterminate,
    );
  }

  Future<void> close() => closeFn(
    tailnetPort: published.port,
    path: published.path,
    funnel: published.funnel,
    generation: published.generation,
    mappingToken: published.mappingToken,
  );
  return TailscalePublishedService._(
    url: published.url,
    port: published.port,
    localAddress: published.localAddress,
    localPort: published.localPort,
    path: published.path,
    https: published.https,
    funnel: published.funnel,
    closeFn: close,
  );
}

final class _PublishedServiceFinalizerToken {
  const _PublishedServiceFinalizerToken(this.close);

  final Future<void> Function() close;
}

final _publishedServiceFinalizer = Finalizer<_PublishedServiceFinalizerToken>((
  token,
) {
  // Finalizers are best-effort and cannot surface failures to a caller. Wrap
  // both synchronous throws and asynchronous errors so an unreachable handle
  // can never produce an unhandled isolate error.
  Future<void>.sync(token.close).ignore();
});
