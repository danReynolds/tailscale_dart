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
// isolate.
//
// Concurrency is capped (see [_offloadGate]). Each in-flight offloaded call
// pins an OS thread inside its synchronous cgo call for the call's whole
// duration, and the Dart VM's thread pool does not shrink back after a helper
// isolate exits — so peak concurrency permanently raises the process thread
// floor (~1 MiB reserved stack each). Without a cap, a burst (e.g. a connection
// pool firing many dials) could exhaust threads/memory on the mobile targets
// this binding supports. The cap replaces the implicit "one at a time" backstop
// the old single-worker path gave us, while still allowing real parallelism.
//
// Note on timeouts: none of these calls is guaranteed-bounded on the Go side.
// `dial`/`ping` default to `null` → an *unbounded* `context.Background()`.
// `funnel.forward`'s outer `s.Up` is bounded by funnelUpTimeout, but
// `ListenFunnel` then calls `s.Up(context.Background())` internally, so a node
// regressing to NeedsLogin can pin it until Stop; `serve.forward`'s LocalAPI
// calls are likewise unbounded. So an abandoned call (a caller-side `.timeout()`
// doesn't cancel it) keeps its helper isolate/thread and Go goroutine until the
// underlying op gives up. The concurrency cap keeps those from accumulating
// without bound (though a burst of stuck calls in one class can starve the
// others through the shared gate); callers wanting a hard per-call bound should
// pass an explicit timeout.
//
// Ordering: offloaded calls are NOT ordered w.r.t. the worker's FIFO calls.
// `forward` in particular no longer happens-before `clear`/`down`/`logout`. The
// awaited handle path is safe — a published service's `close()`→`clear` is built
// only after `forward` completes, so it has a happens-before and Go serializes
// the config mutation. But an *un-awaited* `forward` racing a concurrent
// `down()`/`logout()` can install a funnel forwarder after teardown swept it;
// that requires un-awaited concurrent lifecycle misuse and is a known,
// documented limitation (hardening the Go teardown race is a follow-up).
// ---------------------------------------------------------------------------

/// Caps concurrent helper isolates. Generous enough for real parallelism (a
/// busy connection pool), bounded enough to stay safe on mobile where thread
/// and memory limits are tight; excess calls queue.
const int _maxConcurrentOffloads = 32;
final _offloadGate = _Semaphore(_maxConcurrentOffloads);

/// Runs [nativeOp] on a fresh short-lived isolate and returns its result,
/// subject to the concurrency cap. [nativeOp] must be a top-level/static call
/// capturing only sendable state and returning sendable data; thrown exceptions
/// propagate to the caller with their type and fields intact.
Future<T> _offloadNativeCall<T>(T Function() nativeOp) async {
  await _offloadGate.acquire();
  try {
    return await Isolate.run(nativeOp);
  } finally {
    _offloadGate.release();
  }
}

/// Minimal FIFO counting semaphore. Permits are released in acquire order, so
/// queued offloaded calls run oldest-first.
final class _Semaphore {
  _Semaphore(this._permits);

  int _permits;
  final _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _permits++;
    }
  }
}

/// Test seam: runs [tasks] short tasks through a fresh [_Semaphore] with the
/// given [permits] and returns the peak observed concurrency. Guards that the
/// offload gate actually caps concurrency (F1 regression).
@visibleForTesting
Future<int> debugMaxSemaphoreConcurrency({
  required int permits,
  required int tasks,
}) async {
  final semaphore = _Semaphore(permits);
  var active = 0;
  var peak = 0;
  Future<void> task() async {
    await semaphore.acquire();
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    semaphore.release();
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < tasks; i++) task()]);
  return peak;
}

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
