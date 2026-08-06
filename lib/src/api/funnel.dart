import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../errors.dart';
import 'serve.dart';
import 'serve_validation.dart';

/// Public-internet publication for an existing local HTTP service.
///
/// Reached via [Tailscale.funnel]. Funnel is [Serve.forward] with public
/// ingress turned on: Tailscale publishes this node's MagicDNS HTTPS name to
/// the open internet and proxies requests to the local loopback HTTP service
/// you own. This mirrors `tailscale funnel`, which is `tailscale serve` plus a
/// flag on the same configuration entry.
///
/// Requirements are controlled by the tailnet operator, and none of them can be
/// satisfied from Dart. All three must be in place or [Funnel.forward] throws:
///
/// - HTTPS certificates enabled for the tailnet (admin console -> DNS ->
///   HTTPS Certificates; see https://tailscale.com/kb/1153/enabling-https).
/// - The `funnel` node attribute granted to this node in the tailnet policy
///   file, e.g.
///   `"nodeAttrs": [{"target": ["autogroup:member"], "attr": ["funnel"]}]`.
/// - A policy-approved public port (commonly 443, 8443, 10000).
///
/// A publication serves **both** the public internet and this node's own
/// tailnet, matching `tailscale funnel`.
/// Note the two arrive differently: requests that come in over Funnel are from
/// the anonymous internet and carry no Tailscale identity headers, while
/// tailnet requests do. Authenticate public callers at the forwarded service
/// layer if the endpoint is not intentionally anonymous — do not assume a
/// request reached you over the tailnet.
///
/// Publishing also creates a **public DNS record** for this node's MagicDNS
/// name, which can take a few minutes to appear. A request made immediately
/// after [Funnel.forward] returns may fail until it propagates, and a resolver
/// that cached the earlier NXDOMAIN can hide it for longer.
///
/// Because a publication is one entry, [Funnel.forward] and [Serve.forward] on
/// the same port and path configure the *same* thing rather than two competing
/// ones: calling [Funnel.forward] for a port you already serve turns on public
/// ingress for it, and the later call owns the handler. Use a different path if
/// you want the two to coexist with separate backends.
///
/// Close returned handles explicitly; `Tailscale.down()` also clears
/// package-created publications best-effort.
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
  /// Idempotent: clearing an absent mapping succeeds.
  ///
  /// This withdraws public ingress for the whole `publicPort` — the unit
  /// `AllowFunnel` is keyed by, and what `tailscale funnel <port> off` operates
  /// on — and removes the handler at [path]. Since Funnel and Serve share one
  /// entry per port and path, clearing a publication you created with
  /// [Funnel.forward] also removes the [Serve.forward] handler if it was made
  /// for that same port and path. Use [Serve] for tailnet-only publication.
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
