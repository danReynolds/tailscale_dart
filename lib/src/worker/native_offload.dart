part of 'worker.dart';

// ---------------------------------------------------------------------------
// Off-worker native calls.
//
// A handful of native operations are both LONG (a tailnet round trip) and
// CONTENDED (the caller keeps issuing other operations while they run): dialing
// a peer, pinging a peer, and publishing a serve/funnel mount (which waits for
// the node to reach Running, up to ~30s). Running these on the shared worker
// isolate blocks its synchronous FIFO, stalling every other control call — and
// the state/peer events forwarded by that isolate — behind them. (Measured: a
// single dial to an unreachable peer stalled a concurrent status() for ~7.75s.)
//
// So these run on a short-lived helper isolate instead. One-off `Isolate.run`
// is deliberate over a pool: measured spawn+join is ~0.1ms, negligible against
// these calls' own latency. Each offloaded call is independent — its helper
// isolate handles exactly one call and returns one result — so no request-id
// correlation is needed, and the worker keeps its simple serial FIFO for the
// fast, uncontended local calls that stay on it (status, prefs, listeners, …)
// and the lifecycle calls the caller awaits exclusively anyway (start, logout).
//
// The helper isolate needs no worker-style init: the Go node is process-global
// state shared across all cgo calls, and `@Native` bindings resolve in any
// isolate. Go bounds each operation by the timeout passed in, so abandoning the
// Dart side (e.g. on a caller timeout) never leaks Go work beyond that bound.
// ---------------------------------------------------------------------------

/// Runs [nativeOp] on a fresh short-lived isolate and returns its result.
/// [nativeOp] must be a top-level/static call capturing only sendable state,
/// and must return sendable data; thrown exceptions propagate to the caller
/// with their type and fields intact.
Future<T> _offloadNativeCall<T>(T Function() nativeOp) => Isolate.run(nativeOp);

/// Offloaded `tcp.dial`. Mirrors the shape the API layer expects.
Future<({int fd, TailscaleEndpoint local, TailscaleEndpoint remote})>
offloadTcpDial({required String host, required int port, Duration? timeout}) =>
    _offloadNativeCall(
      () => _execTcpDial(host, port, timeout?.inMilliseconds ?? 0),
    );

({int fd, TailscaleEndpoint local, TailscaleEndpoint remote}) _execTcpDial(
  String host,
  int port,
  int timeoutMillis,
) {
  final hostPtr = host.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneTcpDialFd(hostPtr, port, timeoutMillis),
              onError: TailscaleTcpException.new,
            )
            as Map<String, dynamic>;
    final fd = result['fd'] as int?;
    if (fd == null || fd < 0) {
      throw const TailscaleTcpException(
        'Native runtime did not return a usable TCP fd.',
      );
    }
    return (
      fd: fd,
      local: TailscaleEndpoint(
        address: result['localAddress'] as String? ?? '',
        port: result['localPort'] as int? ?? 0,
      ),
      remote: TailscaleEndpoint(
        address: result['remoteAddress'] as String? ?? '',
        port: result['remotePort'] as int? ?? 0,
      ),
    );
  } finally {
    calloc.free(hostPtr);
  }
}

/// Offloaded `diag.ping`.
Future<PingResult> offloadDiagPing({
  required String ip,
  Duration? timeout,
  required String pingType,
}) => _offloadNativeCall(
  () => _execDiagPing(ip, timeout?.inMilliseconds ?? 0, pingType),
);

PingResult _execDiagPing(String ip, int timeoutMillis, String pingType) {
  final ipPtr = ip.toNativeUtf8();
  final pingTypePtr = pingType.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneDiagPing(ipPtr, timeoutMillis, pingTypePtr),
              onError: TailscaleDiagException.new,
            )
            as Map<String, dynamic>;
    return _parsePingResult(result);
  } finally {
    calloc.free(ipPtr);
    calloc.free(pingTypePtr);
  }
}

/// Offloaded serve/funnel `forward`. The `funnel` flag selects the exception
/// type on failure, matching the previous worker handler.
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
offloadServeForward({
  required int tailnetPort,
  required int localPort,
  required String localAddress,
  required String path,
  required bool https,
  required bool funnel,
}) {
  final payload = jsonEncode({
    'tailnetPort': tailnetPort,
    'localPort': localPort,
    'localAddress': localAddress,
    'path': path,
    'https': https,
    'funnel': funnel,
  });
  return _offloadNativeCall(() => _execServeForward(payload, funnel));
}

({
  Uri url,
  int port,
  String localAddress,
  int localPort,
  String path,
  bool https,
  bool funnel,
})
_execServeForward(String payloadJson, bool funnel) {
  final payloadPtr = payloadJson.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneServeForward(payloadPtr),
              onError: funnel
                  ? TailscaleFunnelException.new
                  : TailscaleServeException.new,
            )
            as Map<String, dynamic>;
    return (
      url: Uri.parse(result['url'] as String? ?? ''),
      port: result['port'] as int? ?? 0,
      localAddress: result['localAddress'] as String? ?? '',
      localPort: result['localPort'] as int? ?? 0,
      path: result['path'] as String? ?? '/',
      https: result['https'] as bool? ?? true,
      funnel: result['funnel'] as bool? ?? false,
    );
  } finally {
    calloc.free(payloadPtr);
  }
}
