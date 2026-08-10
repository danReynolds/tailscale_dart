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
// Concurrency is capped by the caller-isolate gate in
// `native_offload_gate.dart`. HTTP native admission shares that same bound.
// Each in-flight offloaded call
// pins an OS thread inside its synchronous cgo call for the call's whole
// duration, and the Dart VM's thread pool does not shrink back after a helper
// isolate exits — so peak concurrency permanently raises the process thread
// floor (~1 MiB reserved stack each). Without a cap, a burst (e.g. a connection
// pool firing many dials) could exhaust threads/memory on the mobile targets
// this binding supports. The cap replaces the implicit "one at a time" backstop
// the old single-worker path gave us, while still allowing real parallelism.
//
// Note on timeouts: every offloaded call is bounded on the Go side. A caller
// timeout is honored as given; with none, Go applies defaultNativeCallTimeout
// (30s) — `dial`/`ping` contexts and `serve.forward`'s LocalAPI round trips
// are never unbounded. Serve and Funnel mutate the shared ServeConfig directly;
// neither invokes `ListenFunnel` nor starts another `Server.Up`. An abandoned
// call (a caller-side `.timeout()` doesn't cancel native work) still holds its
// helper isolate/thread, gate permit, and Go goroutine, but only until the
// native deadline fires, so stuck calls drain instead of accumulating for the
// life of the process and the shared gate cannot wedge permanently.
//
// Ordering: offloaded calls are NOT ordered w.r.t. the worker's FIFO calls.
// `forward` in particular no longer happens-before `clear`/`down`/`logout`.
// Each `forward` captures its exact runtime token before it can queue here, so
// a delayed runtime-A request cannot enter native against replacement B. After
// a successful config commit, native retains the exact mapping as pending
// delivery until this caller isolate validates the result and acknowledges its
// generation/mapping token. Malformed or lost results actively quarantine A;
// a bounded native acknowledgement timer is the fallback when neither helper
// nor caller isolate can run compensation. Concurrent lifecycle misuse thus
// degrades to a clean error or exact-generation teardown, never stale or
// ownerless ingress.
// ---------------------------------------------------------------------------

/// Event-silent native quarantine receipt used by the caller-isolate
/// supervisor. This path deliberately bypasses the ordinary offload semaphore:
/// rescue must remain available even if every data-plane permit is occupied.
final class RuntimeQuarantineResult {
  const RuntimeQuarantineResult({
    required this.token,
    required this.operation,
    required this.matched,
    required this.started,
    required this.emitStopped,
    required this.pending,
    required this.noState,
    required this.cleanupFailed,
    required this.custodyHeld,
    required this.custodyDisposition,
    required this.error,
  });

  final int token;
  final String? operation;
  final bool matched;
  final bool started;
  final bool emitStopped;
  final bool pending;
  final bool noState;
  final bool cleanupFailed;
  final bool custodyHeld;
  final StateCustodyDisposition custodyDisposition;
  final TailscaleOperationException? error;
}

StateCustodyDisposition _parseCustodyDisposition(
  String? raw, {
  required bool custodyHeld,
}) {
  if (!custodyHeld && (raw == null || raw.isEmpty)) {
    return StateCustodyDisposition.none;
  }
  if (custodyHeld) {
    return switch (raw) {
      'none' => StateCustodyDisposition.none,
      'compensateKey' => StateCustodyDisposition.compensateKey,
      'preserveCoherentPair' => StateCustodyDisposition.preserveCoherentPair,
      _ => throw TailscaleOperationException(
        'runtime quarantine',
        'Native retained state custody without a valid cleanup disposition.',
        code: TailscaleErrorCode.runtimeCleanupFailed,
      ),
    };
  }
  throw TailscaleOperationException(
    'runtime quarantine',
    'Native returned a custody disposition without retaining custody.',
    code: TailscaleErrorCode.runtimeCleanupFailed,
  );
}

Future<RuntimeQuarantineResult> quarantineNativeRuntime(int token) =>
    Isolate.run(() => _execRuntimeQuarantine(token));

RuntimeQuarantineResult _execRuntimeQuarantine(int token) {
  final result =
      _decodeNativeJson(() => native.duneAbandon(token))
          as Map<String, dynamic>;
  final errorMessage = result['error'] as String?;
  final custodyHeld = result['custodyHeld'] == true;
  return RuntimeQuarantineResult(
    token: result['token'] as int? ?? token,
    operation: result['operation'] as String?,
    matched: result['matched'] == true,
    started: result['started'] == true,
    emitStopped: result['emitStopped'] == true,
    pending: result['pending'] == true,
    noState: result['noState'] == true,
    cleanupFailed: result['cleanupFailed'] == true,
    custodyHeld: custodyHeld,
    custodyDisposition: _parseCustodyDisposition(
      result['custodyDisposition'] as String?,
      custodyHeld: custodyHeld,
    ),
    error: errorMessage == null
        ? null
        : TailscaleOperationException(
            'runtime quarantine',
            errorMessage,
            code: parseTailscaleErrorCode(result['code'] as String?),
            statusCode: result['statusCode'] as int?,
          ),
  );
}

/// Shared skeleton for the persistent-lifecycle natives.
///
/// Decodes [invoke]'s JSON envelope and maps a native error payload onto a
/// [TailscaleOperationException] carrying [operation]; [parse] projects the
/// successful result map and is omitted by the void wrappers. With [offload]
/// (the default) the call runs on a short-lived helper isolate because the
/// native side can block on I/O or another owner's settlement. The custody
/// flag flips pass `offload: false` and run via direct FFI on the caller
/// isolate: those natives only take a mutex and flip admission flags — never
/// block, no I/O — matching [supplyTransferredDekToNative], which already
/// calls into the same phase of the same sequence directly.
Future<T> _lifecycleNative<T>(
  String operation,
  ffi.Pointer<Utf8> Function() invoke, {
  bool offload = true,
  T Function(Map<String, dynamic> result)? parse,
}) {
  T run() {
    final result = _callNativeJson(
      invoke,
      onError: (message, {code = TailscaleErrorCode.unknown, statusCode}) =>
          TailscaleOperationException(
            operation,
            message,
            code: code,
            statusCode: statusCode,
          ),
    );
    final project = parse;
    // Void wrappers ignore the decoded envelope; `null as T` reifies cleanly
    // because a void type argument admits any value.
    if (project == null) return null as T;
    return project(result as Map<String, dynamic>);
  }

  return offload ? Isolate.run(run) : Future<T>.sync(run);
}

Future<void> beginNativePersistentPreparation(int token) => _lifecycleNative(
  'state preparation',
  () => native.duneBeginPersistentPreparation(token),
);

Future<String> inspectNativePersistentPreparation(int token) =>
    _lifecycleNative(
      'state preparation',
      () => native.duneInspectPersistentPreparation(token),
      parse: (result) => result['layout'] as String? ?? '',
    );

Future<void> markNativeCustodyActive(int token) => _lifecycleNative(
  'state custody',
  () => native.duneMarkCustodyActive(token),
  offload: false,
);

Future<void> markNativeCustodyWriteAttempted(int token) => _lifecycleNative(
  'state custody',
  () => native.duneMarkCustodyWriteAttempted(token),
  offload: false,
);

Future<String> resolveNativePersistentCustody(
  int token, {
  required bool dekPresent,
}) => _lifecycleNative(
  'state custody',
  () => native.duneResolvePersistentCustody(token, dekPresent ? 1 : 0),
  offload: false,
  parse: (result) => result['action'] as String? ?? '',
);

Future<bool> prepareNativePersistentState(int token) => _lifecycleNative(
  'state preparation',
  () => native.dunePreparePersistentState(token),
  parse: (result) => result['empty'] == true,
);

Future<void> completeNativePersistentCustody(int token) => _lifecycleNative(
  'state custody',
  () => native.duneCompletePersistentCustody(token),
  offload: false,
);

Future<void> finishNativePreparedPersistentState(int token) => _lifecycleNative(
  'state preparation',
  () => native.duneFinishPreparedPersistentState(token),
);

/// Receipt from the pre-Keybay half of an explicit local reset. [stopped]
/// remains available even when [error] is non-null so Dart can retire the
/// worker generation that native already detached.
final class NativeLocalResetBeginResult {
  const NativeLocalResetBeginResult({
    required this.token,
    required this.stopped,
    required this.error,
  });

  final int token;
  final bool stopped;
  final TailscaleOperationException? error;
}

Future<NativeLocalResetBeginResult> beginNativeLocalReset(int token) =>
    Isolate.run(() {
      final result =
          _decodeNativeJson(() => native.duneBeginLocalReset(token))
              as Map<String, dynamic>;
      final message = result['error'] as String?;
      return NativeLocalResetBeginResult(
        token: result['token'] as int? ?? token,
        stopped: result['stopped'] == true,
        error: message == null
            ? null
            : TailscaleOperationException(
                'forget local identity',
                message,
                code: parseTailscaleErrorCode(result['code'] as String?),
                statusCode: result['statusCode'] as int?,
              ),
      );
    });

Future<void> finishNativeLocalReset(
  int token, {
  required bool custodyDeletionSucceeded,
}) => _lifecycleNative(
  'forget local identity',
  () => native.duneFinishLocalReset(token, custodyDeletionSucceeded ? 1 : 0),
);

Future<void> finishNativeCustody(int token, {required bool cleanupSucceeded}) =>
    _lifecycleNative(
      'state custody',
      () => native.duneFinishCustody(token, cleanupSucceeded ? 1 : 0),
    );

Future<void> awaitNativeRuntimeQuiescence(int token) => _lifecycleNative(
  'runtime quarantine',
  () => native.duneAwaitRuntimeQuiescence(token),
);

Future<void> retireNativeAbandonedRuntimeToken(int token) => _lifecycleNative(
  'runtime quarantine',
  () => native.duneRetireAbandonedRuntimeToken(token),
);

/// Test seam: runs [tasks] short tasks through a fresh [_Semaphore] with the
/// given [permits] and returns the peak observed concurrency. Guards that the
/// offload gate actually caps concurrency (F1 regression).
@visibleForTesting
Future<int> debugMaxSemaphoreConcurrency({
  required int permits,
  required int tasks,
}) {
  // Deliberate forwarding seam: tests import this worker-facing library while
  // the shared semaphore implementation remains isolated in its own library.
  // ignore: invalid_use_of_visible_for_testing_member
  return debugMaxNativeOffloadConcurrency(permits: permits, tasks: tasks);
}

/// Offloaded `tcp.dial`. Mirrors the shape the API layer expects.
Future<({int fd, TailscaleEndpoint local, TailscaleEndpoint remote})>
offloadTcpDial({
  required int runtimeToken,
  required String host,
  required int port,
  Duration? timeout,
}) => runCappedNativeOffload(
  () => _execTcpDial(runtimeToken, host, port, timeout?.inMilliseconds ?? 0),
);

({int fd, TailscaleEndpoint local, TailscaleEndpoint remote}) _execTcpDial(
  int runtimeToken,
  String host,
  int port,
  int timeoutMillis,
) {
  final hostPtr = host.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneTcpDialFd(
                runtimeToken,
                hostPtr,
                port,
                timeoutMillis,
              ),
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
  required int runtimeToken,
  required String ip,
  Duration? timeout,
  required String pingType,
}) => runCappedNativeOffload(
  () => _execDiagPing(runtimeToken, ip, timeout?.inMilliseconds ?? 0, pingType),
);

PingResult _execDiagPing(
  int runtimeToken,
  String ip,
  int timeoutMillis,
  String pingType,
) {
  final ipPtr = ip.toNativeUtf8();
  final pingTypePtr = pingType.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneDiagPing(
                runtimeToken,
                ipPtr,
                timeoutMillis,
                pingTypePtr,
              ),
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
Future<ServeForwardResult> offloadServeForward({
  required int runtimeToken,
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
  return _completePublicationDelivery(
    runtimeToken: runtimeToken,
    funnel: funnel,
    dispatch: () => guardPublicationResultDeliveryForTesting(
      dispatch: () => runCappedNativeOffload(
        () => _execServeForward(
          runtimeToken,
          payload,
          funnel: funnel,
          tailnetPort: tailnetPort,
          path: path,
        ),
      ),
      onResultLoss: () => _execFailPublicationDelivery(runtimeToken, funnel),
    ),
  );
}

ServeForwardResult _execServeForward(
  int runtimeToken,
  String payloadJson, {
  required bool funnel,
  required int tailnetPort,
  required String path,
}) {
  final payloadPtr = payloadJson.toNativeUtf8();
  try {
    final result =
        _callNativeJson(
              () => native.duneServeForward(runtimeToken, payloadPtr),
              onError: _publicationException(funnel),
            )
            as Map<String, dynamic>;
    return validateServeForwardResultForTesting(
      result,
      funnel: funnel,
      tailnetPort: tailnetPort,
      path: path,
      onInvalid: () => _execFailPublicationDelivery(runtimeToken, funnel),
    );
  } on TailscaleOperationException {
    rethrow;
  } catch (error, stackTrace) {
    try {
      _execFailPublicationDelivery(runtimeToken, funnel);
    } catch (cleanupError, cleanupStackTrace) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace);
    }
    Error.throwWithStackTrace(
      _publicationDeliveryException(
        funnel,
        'Native returned an unreadable publication result.',
        cause: error,
      ),
      stackTrace,
    );
  } finally {
    calloc.free(payloadPtr);
  }
}

@visibleForTesting
ServeForwardResult validateServeForwardResultForTesting(
  Map<String, dynamic> result, {
  required bool funnel,
  required int tailnetPort,
  required String path,
  void Function()? onInvalid,
}) {
  final url = Uri.tryParse(result['url'] as String? ?? '');
  final port = result['port'] as int?;
  final localAddress = result['localAddress'] as String?;
  final localPort = result['localPort'] as int?;
  final resultPath = result['path'] as String?;
  final https = result['https'] as bool?;
  final resultFunnel = result['funnel'] as bool?;
  final generation = result['generation'] as int?;
  final mappingToken = result['mappingToken'] as int?;
  if (generation == null ||
      generation <= 0 ||
      mappingToken == null ||
      mappingToken <= 0 ||
      url == null ||
      !url.hasScheme ||
      url.host.isEmpty ||
      port == null ||
      port != tailnetPort ||
      localAddress == null ||
      localAddress.isEmpty ||
      localPort == null ||
      localPort <= 0 ||
      resultPath == null ||
      resultPath != path ||
      https == null ||
      resultFunnel == null ||
      resultFunnel != funnel) {
    onInvalid?.call();
    _throwInvalidPublicationResult(funnel);
  }
  return (
    url: url,
    port: port,
    localAddress: localAddress,
    localPort: localPort,
    path: resultPath,
    https: https,
    funnel: resultFunnel,
    generation: generation,
    mappingToken: mappingToken,
  );
}

Future<ServeForwardResult> _completePublicationDelivery({
  required int runtimeToken,
  required bool funnel,
  required Future<ServeForwardResult> Function() dispatch,
}) async {
  late final ServeForwardResult publication;
  try {
    publication = await dispatch();
  } on TailscaleOperationException {
    rethrow;
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      _publicationDeliveryException(
        funnel,
        'Publication result was lost before exact handle delivery.',
        cause: error,
      ),
      stackTrace,
    );
  }

  try {
    _execAcknowledgePublication(runtimeToken, publication, funnel);
  } catch (error, stackTrace) {
    try {
      _execFailPublicationDelivery(runtimeToken, funnel);
    } catch (cleanupError, cleanupStackTrace) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace);
    }
    if (error is TailscaleOperationException) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    Error.throwWithStackTrace(
      _publicationDeliveryException(
        funnel,
        'Publication acknowledgement was lost.',
        cause: error,
      ),
      stackTrace,
    );
  }
  return publication;
}

@visibleForTesting
Future<T> guardPublicationResultDeliveryForTesting<T>({
  required Future<T> Function() dispatch,
  required void Function() onResultLoss,
}) async {
  try {
    return await dispatch();
  } on TailscaleOperationException {
    // A typed exception is a successfully delivered native rejection. Native
    // either proved no commit or already quarantined an indeterminate commit.
    rethrow;
  } catch (error, stackTrace) {
    onResultLoss();
    Error.throwWithStackTrace(error, stackTrace);
  }
}

void _execAcknowledgePublication(
  int runtimeToken,
  ServeForwardResult publication,
  bool funnel,
) {
  _callNativeJson(
    () => native.duneAcknowledgePublication(
      runtimeToken,
      publication.generation,
      publication.mappingToken,
    ),
    onError: _publicationException(funnel),
  );
}

void _execFailPublicationDelivery(int runtimeToken, bool funnel) {
  _callNativeJson(
    () => native.duneFailPublicationDelivery(runtimeToken),
    onError: _publicationException(funnel),
  );
}

/// Constructor shape shared by [TailscaleFunnelException] and
/// [TailscaleServeException]; what [_publicationException] returns.
typedef _PublicationExceptionFactory =
    TailscaleOperationException Function(
      String message, {
      TailscaleErrorCode code,
      int? statusCode,
      Object? cause,
    });

/// Selects the Serve or Funnel exception flavor for one publication-path
/// failure, so every site derives its type from the same `funnel` flag.
_PublicationExceptionFactory _publicationException(bool funnel) =>
    funnel ? TailscaleFunnelException.new : TailscaleServeException.new;

TailscaleOperationException _publicationDeliveryException(
  bool funnel,
  String message, {
  Object? cause,
}) => _publicationException(funnel)(
  message,
  code: TailscaleErrorCode.publicationCommitIndeterminate,
  cause: cause,
);

Never _throwInvalidPublicationResult(bool funnel) =>
    throw _publicationException(funnel)(
      'Native runtime returned a publication without a valid exact handle.',
      code: TailscaleErrorCode.publicationCommitIndeterminate,
    );
