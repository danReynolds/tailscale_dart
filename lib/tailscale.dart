import 'dart:async';
import 'dart:convert';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as pkg_http;
import 'package:meta/meta.dart';
import 'src/api/diag.dart';
import 'src/api/exit_node.dart';
import 'src/api/funnel.dart';
import 'src/api/http.dart';
import 'src/api/identity.dart';
import 'src/api/prefs.dart';
import 'src/api/profiles.dart';
import 'src/api/serve.dart';
import 'src/api/taildrop.dart';
import 'src/api/tcp.dart';
import 'src/api/tls.dart';
import 'src/api/udp.dart';
import 'src/errors.dart';
import 'src/fd_transport.dart' show ensurePosixFdTransportAvailable;
import 'src/ffi_bindings.dart' as native;
import 'src/http_fd_client.dart';
import 'src/runtime_config.dart';
import 'src/status.dart';
import 'src/worker/worker.dart';

export 'src/api/diag.dart'
    hide
        createDiag,
        DiagPingFn,
        DiagMetricsFn,
        DiagDERPMapFn,
        DiagCheckUpdateFn;
export 'src/api/connection.dart'
    hide createFdTailscaleConnection, createFdTailscaleListener;
export 'src/api/exit_node.dart'
    hide
        createExitNode,
        ExitNodeCurrentFn,
        ExitNodeSuggestFn,
        ExitNodeUseByIdFn,
        ExitNodeUseAutoFn,
        ExitNodeClearFn;
export 'src/api/funnel.dart' hide createFunnel;
export 'src/api/http.dart' hide createHttp, createHttpRequestForTesting;
export 'src/api/identity.dart';
export 'src/api/prefs.dart' hide createPrefs, PrefsGetFn, PrefsUpdateFn;
export 'src/api/profiles.dart';
export 'src/api/serve.dart'
    hide
        createServe,
        createPublishedServiceForFunnel,
        ServeForwardFn,
        ServeClearFn;
export 'src/api/taildrop.dart';
export 'src/api/tcp.dart'
    hide createTcp, TcpDialFn, TcpListenFn, TcpCloseListenerFn;
export 'src/api/tls.dart'
    hide createTls, TlsListenFn, TlsCloseListenerFn, TlsDomainsFn;
export 'src/api/udp.dart'
    hide createUdp, createFdTailscaleDatagramBinding, UdpBindFn;
export 'src/errors.dart';
export 'src/status.dart';

/// Native log verbosity for the embedded Tailscale runtime — controls
/// what the Go side writes to stderr. Dart-side logging (e.g.
/// [TailscaleRuntimeError]) is unaffected.
enum TailscaleLogLevel {
  /// No native logs at all.
  silent,

  /// Only error-level log lines.
  error,

  /// Informational + error logs. Useful during development; noisy in
  /// production.
  info,
}

extension on TailscaleLogLevel {
  int get nativeValue => switch (this) {
    TailscaleLogLevel.silent => 0,
    TailscaleLogLevel.error => 1,
    TailscaleLogLevel.info => 2,
  };
}

/// Testable app-facing contract for an embedded Tailscale node.
///
/// Production code usually gets the real implementation from
/// [Tailscale.instance]. App code can depend on this interface instead, which
/// allows unit tests to provide a fake without loading the native runtime.
abstract interface class TailscaleClient {
  Tcp get tcp;
  Tls get tls;
  Udp get udp;
  Funnel get funnel;
  Http get http;

  Taildrop get taildrop;
  Serve get serve;
  ExitNode get exitNode;
  Profiles get profiles;
  Prefs get prefs;
  Diag get diag;

  Stream<NodeState> get onStateChange;
  Stream<List<TailscaleNode>> get onNodeChanges;
  Stream<TailscaleRuntimeError> get onError;

  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    bool ephemeral = false,
    Uri? controlUrl,
    Duration timeout = const Duration(seconds: 30),
  });

  Future<TailscaleStatus> status();
  Future<List<TailscaleNode>> nodes();
  Future<TailscaleNode?> nodeByIp(String ip);
  Future<TailscaleNodeIdentity?> whois(String ip);
  Future<void> down();
  Future<void> logout();
}

/// Singleton embedded Tailscale node for the current Dart process.
/// Wraps Tailscale's [tsnet](https://tailscale.com/docs/features/tsnet)
/// userspace library — the Dart app itself becomes a node on the
/// tailnet, no OS-level VPN required.
///
/// This package runs one node per process. Configure it once with
/// [init], then access the singleton through [instance].
///
/// ## Shape
///
/// - **Lifecycle** (top-level): [up], [down], [logout], [status], [nodes],
///   [nodeByIp], [onStateChange], [onNodeChanges], [onError].
/// - **Transport primitives** (namespaced): [tcp], [tls], [udp], [funnel],
///   [http]. Raw TCP uses package-native connection/listener types.
/// - **Feature namespaces**: [taildrop], [serve], [exitNode], [profiles],
///   [prefs].
/// - **Diagnostics**: [diag].
/// - **Identity**: [whois].
class Tailscale implements TailscaleClient {
  Tailscale._();
  static final Tailscale instance = Tailscale._();

  static String? _stateBaseDir;

  pkg_http.Client? _http;
  List<TailscaleNode>? _latestNodes;
  bool _nativeStartInFlight = false;
  Worker? _workerInstance;
  Future<void>? _workerRecovery;
  TailscaleOperationException? _workerRecoveryFailure;
  TailscaleStatusException? _idleStatusError;
  final Set<int> _shutdownIntents = <int>{};
  final Map<int, RuntimeQuarantineResult> _recoveredShutdowns =
      <int, RuntimeQuarantineResult>{};
  int _nextRuntimeToken = 1;
  final LifecycleQueue _supervisorLifecycle = LifecycleQueue();
  int? _activeUpToken;
  Completer<Object?>? _activeUpWorkerExit;

  // Singleton broadcast controllers — live for the process lifetime alongside
  // the embedded Tailscale engine; intentionally never closed.
  // ignore: close_sinks
  final StreamController<NodeState> _stateController =
      StreamController<NodeState>.broadcast();
  // ignore: close_sinks
  final StreamController<TailscaleRuntimeError> _errorController =
      StreamController<TailscaleRuntimeError>.broadcast();
  // ignore: close_sinks
  final StreamController<List<TailscaleNode>> _nodesController =
      StreamController<List<TailscaleNode>>.broadcast();

  static String _requireStateBaseDir() {
    final stateBaseDir = _stateBaseDir;
    if (stateBaseDir == null) {
      throw const TailscaleUsageException(
        'Call Tailscale.init(stateDir: ...) before using Tailscale.instance.',
      );
    }
    return stateBaseDir;
  }

  static void _requireInitialized() {
    _requireStateBaseDir();
  }

  int _allocateRuntimeToken() {
    final token = _nextRuntimeToken++;
    if (_nextRuntimeToken <= 0) _nextRuntimeToken = 1;
    return token;
  }

  Worker _spawnWorker() => Worker(
    publishState: _stateController.add,
    publishRuntimeError: _errorController.add,
    publishNodes: _publishNodes,
    onExit: _handleWorkerExit,
  );

  Future<void> _awaitWorkerRecoveryCompletion() async {
    while (true) {
      final recovery = _workerRecovery;
      if (recovery == null) break;
      await recovery;
    }
  }

  Future<void> _awaitWorkerRecovery() async {
    await _awaitWorkerRecoveryCompletion();
    final failure = _workerRecoveryFailure;
    if (failure != null) throw failure;
  }

  Future<Worker> _workerForCall() async {
    await _awaitWorkerRecovery();
    return _currentOrSpawnWorker();
  }

  Worker _currentOrSpawnWorker() {
    final current = _workerInstance;
    if (current != null && !current.isDisposed) return current;
    final replacement = _spawnWorker();
    _workerInstance = replacement;
    return replacement;
  }

  Future<T> _withWorker<T>(Future<T> Function(Worker worker) operation) async {
    return await operation(await _workerForCall());
  }

  Future<T> _withNativeRuntime<T>(Future<T> Function() operation) async {
    await _awaitWorkerRecovery();
    return await operation();
  }

  void _trackWorkerRecovery(Future<void> Function() recovery) {
    final previous = _workerRecovery;
    // Queue the recovery operation itself, not merely its completion. Rescue
    // and idle-state classification must never overlap for two lifecycle
    // incidents, otherwise an older classifier can observe or publish a newer
    // generation's state.
    final ordered = (previous ?? Future<void>.value()).then<void>(
      (_) => recovery(),
    );
    final tracked = ordered.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _workerRecoveryFailure ??= TailscaleOperationException(
          'worker recovery',
          'Native runtime recovery failed; further native work is blocked.',
          code: TailscaleErrorCode.workerTerminated,
          cause: error,
        );
      },
    );
    _workerRecovery = tracked;
    unawaited(
      tracked.then((_) {
        if (identical(_workerRecovery, tracked)) {
          _workerRecovery = null;
        }
      }),
    );
  }

  void _handleWorkerExit(
    Worker worker,
    int? runtimeToken,
    bool expected,
    Object? cause,
  ) {
    if (!identical(_workerInstance, worker)) return;
    _workerInstance = null;
    final activeUpExit = _activeUpWorkerExit;
    if (_activeUpToken != null &&
        activeUpExit != null &&
        !activeUpExit.isCompleted) {
      activeUpExit.complete(cause);
    }
    _reset();
    _trackWorkerRecovery(
      () => _recoverExitedWorker(
        runtimeToken: runtimeToken,
        expected: expected,
        cause: cause,
      ),
    );
  }

  Future<void> _recoverExitedWorker({
    required int? runtimeToken,
    required bool expected,
    required Object? cause,
  }) async {
    RuntimeQuarantineResult? quarantine;
    Object? rescueFailure;
    var cleanupRescueFailure = false;
    try {
      final token = runtimeToken ?? 0;
      quarantine = await quarantineNativeRuntime(token);
      final quarantineError = quarantine.error;
      final hasTerminalReceipt = quarantine.operation != null;
      if (!hasTerminalReceipt && quarantineError != null) {
        throw quarantineError;
      }
      if (!hasTerminalReceipt && quarantine.pending) {
        await awaitNativeRuntimeQuiescence(token);
      }
      if (hasTerminalReceipt && quarantine.cleanupFailed) {
        _retainCleanupFailure(
          quarantineError?.code == TailscaleErrorCode.runtimeCleanupFailed
              ? quarantineError!
              : TailscaleOperationException(
                  'worker recovery',
                  'The completed lifecycle operation did not cleanly close '
                      'all native resources.',
                  code: TailscaleErrorCode.runtimeCleanupFailed,
                  cause: quarantineError,
                ),
        );
      }
    } catch (error) {
      rescueFailure = error;
      if (error is TailscaleOperationException &&
          error.code == TailscaleErrorCode.runtimeCleanupFailed) {
        cleanupRescueFailure = true;
        _retainCleanupFailure(error);
      } else {
        _workerRecoveryFailure = TailscaleOperationException(
          'worker recovery',
          'Failed to quarantine the native runtime after worker termination.',
          code: TailscaleErrorCode.workerTerminated,
          cause: error,
        );
      }
    }

    final hasTerminalReceipt = quarantine?.operation != null;
    TailscaleStatus? idleStatus;
    Object? classificationFailure;
    if (rescueFailure == null && !hasTerminalReceipt) {
      try {
        idleStatus = await classifyNativeIdleStatus();
        _requireQuiescentStatus(idleStatus);
        _idleStatusError = null;
      } catch (error) {
        classificationFailure = error;
        _idleStatusError = error is TailscaleStatusException
            ? error
            : TailscaleStatusException(
                'Failed to classify state after worker termination.',
                cause: error,
              );
      }
    } else if (rescueFailure != null && !cleanupRescueFailure) {
      _idleStatusError = TailscaleStatusException(
        'Native state could not be classified because runtime quarantine '
        'failed.',
        code: TailscaleErrorCode.workerTerminated,
        cause: rescueFailure,
      );
    }

    if (!expected) {
      final details = <String>[
        'The supervised Tailscale worker terminated unexpectedly.',
        if (cause != null) 'Cause: $cause',
        if (rescueFailure != null) 'Native quarantine failed: $rescueFailure',
        if (classificationFailure != null)
          'State classification failed: $classificationFailure',
      ];
      _errorController.add(
        TailscaleRuntimeError(
          message: details.join(' '),
          code: TailscaleRuntimeErrorCode.worker,
        ),
      );
    }
    if (hasTerminalReceipt && quarantine != null) {
      final receiptError = quarantine.error;
      if (quarantine.cleanupFailed) {
        _idleStatusError = TailscaleStatusException(
          'Native teardown did not reach a proven quiescent state.',
          code: TailscaleErrorCode.runtimeCleanupFailed,
          cause: receiptError,
        );
      } else {
        _idleStatusError = null;
        _publishQuiescentReceipt(quarantine);
      }
      if (quarantine.started || quarantine.noState) {
        _publishTerminalNodes();
      }
    } else if (idleStatus != null) {
      _publishQuiescentState(
        emitStopped: quarantine?.emitStopped == true,
        idleStatus: idleStatus,
      );
      if (quarantine?.started == true ||
          idleStatus.state == NodeState.noState) {
        _publishTerminalNodes();
      }
    } else if (quarantine?.started == true) {
      _publishTerminalNodes();
    }

    final token = runtimeToken ?? 0;
    if (quarantine != null &&
        (rescueFailure == null || quarantine.error != null) &&
        _shutdownIntents.contains(token)) {
      _recoveredShutdowns[token] = quarantine;
    }
  }

  static void _requireQuiescentStatus(TailscaleStatus status) {
    if (status.state == NodeState.stopped ||
        status.state == NodeState.noState) {
      return;
    }
    throw TailscaleStatusException(
      'Native runtime remained ${status.state.name} after quarantine.',
      code: TailscaleErrorCode.workerTerminated,
    );
  }

  void _publishQuiescentState({
    required bool emitStopped,
    required TailscaleStatus idleStatus,
  }) {
    if (emitStopped) {
      _stateController.add(NodeState.stopped);
    }
    // `stopped` is a transition only when the caller-visible runtime was active
    // and actually detached. A temporary runtime reconstructed by idle logout
    // stays hidden. `noState` remains useful after confirmed upstream logout
    // or a clean idle root, including an acknowledgement lost with the worker.
    if (idleStatus.state == NodeState.noState) {
      _stateController.add(NodeState.noState);
    }
  }

  void _publishQuiescentReceipt(RuntimeQuarantineResult receipt) {
    // A cleanup failure means detach was attempted, not that quiescence was
    // proved. Its typed error is the only truthful public outcome.
    if (receipt.cleanupFailed) return;
    if (receipt.error != null) {
      if (receipt.error?.code == TailscaleErrorCode.logoutIndeterminate &&
          receipt.emitStopped) {
        _stateController.add(NodeState.stopped);
      }
      return;
    }
    if (receipt.emitStopped) {
      _stateController.add(NodeState.stopped);
    }
    if (receipt.noState) {
      _stateController.add(NodeState.noState);
    }
  }

  void _retainCleanupFailure(TailscaleOperationException error) {
    _workerRecoveryFailure ??= TailscaleOperationException(
      'worker recovery',
      'Native cleanup failed; restart the process before further native work.',
      code: TailscaleErrorCode.runtimeCleanupFailed,
      cause: error,
    );
    _idleStatusError = TailscaleStatusException(
      'Native teardown did not reach a proven quiescent state.',
      code: TailscaleErrorCode.runtimeCleanupFailed,
      cause: error,
    );
  }

  Future<void> _quarantineTimedOutStart(Worker worker, int token) async {
    worker.detachRuntimeToken(token);

    final quarantined = Completer<void>();
    _trackWorkerRecovery(() async {
      try {
        final result = await quarantineNativeRuntime(token);
        if (result.matched) {
          _reset();
        }
        final quarantineError = result.error;
        if (quarantineError != null) throw quarantineError;
        if (!quarantined.isCompleted) quarantined.complete();
        // An idempotent up() can time out before receiving the existing
        // runtime token. Quarantining its request token correctly matches
        // nothing; do not reset, classify, or republish that live runtime.
        if (!result.matched) return;
        if (result.pending) {
          await awaitNativeRuntimeQuiescence(token);
        }

        try {
          final idleStatus = await classifyNativeIdleStatus();
          _requireQuiescentStatus(idleStatus);
          _idleStatusError = null;
          _publishQuiescentState(
            emitStopped: result.emitStopped,
            idleStatus: idleStatus,
          );
        } catch (error) {
          _idleStatusError = error is TailscaleStatusException
              ? error
              : TailscaleStatusException(
                  'Failed to classify state after startup quarantine.',
                  cause: error,
                );
          _errorController.add(
            TailscaleRuntimeError(
              message:
                  'Startup was quarantined, but persisted state could not be '
                  'classified: $error',
              code: TailscaleRuntimeErrorCode.worker,
            ),
          );
        }
      } catch (error, stackTrace) {
        _reset();
        _workerRecoveryFailure = TailscaleOperationException(
          'worker recovery',
          'Failed to quarantine a timed-out native startup.',
          code: TailscaleErrorCode.workerTerminated,
          cause: error,
        );
        if (!quarantined.isCompleted) {
          quarantined.completeError(error, stackTrace);
        }
      }
    });
    await quarantined.future;
  }

  void _reset() {
    _http?.close();
    _http = null;
    _latestNodes = null;
  }

  void _publishTerminalNodes() {
    const empty = <TailscaleNode>[];
    _latestNodes = empty;
    _nodesController.add(empty);
  }

  void _publishNodes(List<TailscaleNode> nodes) {
    final snapshot = List<TailscaleNode>.unmodifiable(nodes);
    _latestNodes = snapshot;
    _nodesController.add(snapshot);
  }

  Future<List<TailscaleNode>> _snapshotNodes() async {
    final nodes = await _withWorker((worker) => worker.nodes());
    final snapshot = List<TailscaleNode>.unmodifiable(nodes);
    _latestNodes = snapshot;
    return snapshot;
  }

  static bool _sameNodes(List<TailscaleNode>? a, List<TailscaleNode>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ─── Transport namespaces ───────────────────────────────────────────
  @override
  late final Tcp tcp = createTcp(
    // Offloaded to a helper isolate: dial is long (a tailnet round trip) and
    // contended (callers dial/status concurrently), so it must not block the
    // worker. See lib/src/worker/native_offload.dart.
    dialFn: (host, port, timeout) => _withNativeRuntime(
      () => offloadTcpDial(host: host, port: port, timeout: timeout),
    ),
    listenFn: (tailnetPort, tailnetHost) => _withWorker(
      (worker) => worker.tcpListenFd(
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
      ),
    ),
    closeListenerFn: (listenerId) =>
        _withWorker((worker) => worker.closeFdListener(listenerId: listenerId)),
  );
  @override
  late final Tls tls = createTls(
    listenFn: (tailnetPort, tailnetHost) => _withWorker(
      (worker) => worker.tlsListenFd(
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
      ),
    ),
    closeListenerFn: (listenerId) =>
        _withWorker((worker) => worker.closeFdListener(listenerId: listenerId)),
    domainsFn: () => _withWorker((worker) => worker.tlsDomains()),
  );
  @override
  late final Udp udp = createUdp(
    bindFn: (host, port) =>
        _withWorker((worker) => worker.udpBindFd(host: host, port: port)),
    defaultAddressFn: () async => (await status()).ipv4,
    closeFn: (bindingId) =>
        _withWorker((worker) => worker.udpCloseBinding(bindingId: bindingId)),
  );
  @override
  late final Funnel funnel = createFunnel(
    forwardFn:
        ({
          required tailnetPort,
          required localPort,
          required localAddress,
          required path,
          required https,
          required funnel,
        }) => _withNativeRuntime(
          () => offloadServeForward(
            tailnetPort: tailnetPort,
            localPort: localPort,
            localAddress: localAddress,
            path: path,
            https: https,
            funnel: funnel,
          ),
        ),
    clearFn: ({required tailnetPort, required path, required funnel}) =>
        _withWorker(
          (worker) => worker.serveClear(
            tailnetPort: tailnetPort,
            path: path,
            funnel: funnel,
          ),
        ),
  );
  @override
  late final Http http = createHttp(
    clientGetter: () => _http,
    bindFn: (port) =>
        _withWorker((worker) => worker.httpBind(tailnetPort: port)),
    closeBindingFn: (bindingId) =>
        _withWorker((worker) => worker.httpCloseBinding(bindingId: bindingId)),
  );

  // ─── Feature namespaces ─────────────────────────────────────────────
  @override
  final Taildrop taildrop = Taildrop.instance;
  @override
  late final Serve serve = createServe(
    forwardFn:
        ({
          required tailnetPort,
          required localPort,
          required localAddress,
          required path,
          required https,
          required funnel,
        }) => _withNativeRuntime(
          () => offloadServeForward(
            tailnetPort: tailnetPort,
            localPort: localPort,
            localAddress: localAddress,
            path: path,
            https: https,
            funnel: funnel,
          ),
        ),
    clearFn: ({required tailnetPort, required path, required funnel}) =>
        _withWorker(
          (worker) => worker.serveClear(
            tailnetPort: tailnetPort,
            path: path,
            funnel: funnel,
          ),
        ),
  );
  @override
  late final ExitNode exitNode = createExitNode(
    currentFn: _currentExitNode,
    suggestFn: _suggestExitNode,
    useByIdFn: (stableNodeId) async {
      await _withWorker(
        (worker) => worker.prefsUpdate(PrefsUpdate(exitNodeId: stableNodeId)),
      );
    },
    useAutoFn: () => _withWorker((worker) => worker.exitNodeUseAuto()),
    clearFn: () async {
      await _withWorker(
        (worker) => worker.prefsUpdate(const PrefsUpdate(exitNodeId: '')),
      );
    },
    nodeChanges: onNodeChanges,
  );
  @override
  final Profiles profiles = Profiles.instance;
  @override
  late final Prefs prefs = createPrefs(
    getFn: () => _withWorker((worker) => worker.prefsGet()),
    updateFn: (update) => _withWorker((worker) => worker.prefsUpdate(update)),
  );

  // ─── Diagnostics ────────────────────────────────────────────────────
  @override
  late final Diag diag = createDiag(
    // Offloaded to a helper isolate (long + contended, like dial).
    pingFn: (ip, timeout, type) => _withNativeRuntime(
      () => offloadDiagPing(ip: ip, timeout: timeout, pingType: type.name),
    ),
    metricsFn: () => _withWorker((worker) => worker.diagMetrics()),
    derpMapFn: () => _withWorker((worker) => worker.diagDERPMap()),
    checkUpdateFn: () => _withWorker((worker) => worker.diagCheckUpdate()),
    nodeStateFn: () => _withWorker((worker) => worker.debugNodeState()),
  );

  // ─── Streams ────────────────────────────────────────────────────────

  /// Emits the new [NodeState] whenever the node's lifecycle state changes.
  ///
  /// Consecutive duplicates are filtered except for [NodeState.needsLogin].
  /// A re-auth attempt can produce another `needsLogin` with a fresh auth URL;
  /// callers commonly respond to the state event by calling [status], so those
  /// repeats remain observable.
  @override
  Stream<NodeState> get onStateChange => Stream<NodeState>.multi((controller) {
    NodeState? last;
    final subscription = _stateController.stream.listen(
      (state) {
        if (state == last && state != NodeState.needsLogin) return;
        last = state;
        controller.add(state);
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Emits the full node list on any change (node joined, left,
  /// went on/off-line, tags or DNS name changed).
  ///
  /// Saves callers from polling [nodes] on a timer. Derived from
  /// the same IPN bus `NotifyInitialNetMap` subscription as
  /// [onStateChange]; subscribers get the current node inventory as
  /// the first emission, then one emission per inventory change.
  @override
  Stream<List<TailscaleNode>> get onNodeChanges =>
      Stream<List<TailscaleNode>>.multi((controller) {
        var canceled = false;
        List<TailscaleNode>? lastEmitted;

        void emitIfChanged(List<TailscaleNode> nodes) {
          if (_sameNodes(lastEmitted, nodes)) return;
          lastEmitted = nodes;
          controller.add(nodes);
        }

        final subscription = _nodesController.stream.listen(
          emitIfChanged,
          onError: controller.addError,
          onDone: controller.close,
        );

        unawaited(() async {
          try {
            final snapshot = _latestNodes ?? await _snapshotNodes();
            if (!canceled) {
              emitIfChanged(snapshot);
            }
          } catch (error, stackTrace) {
            if (!canceled) {
              controller.addError(error, stackTrace);
            }
          }
        }());

        controller.onCancel = () {
          canceled = true;
          return subscription.cancel();
        };
      }, isBroadcast: true);

  /// Background runtime errors pushed from the embedded node.
  @override
  Stream<TailscaleRuntimeError> get onError => _errorController.stream;

  // ─── Lifecycle ──────────────────────────────────────────────────────

  /// Configures the Tailscale library. Call this once at app startup,
  /// alongside other library initializers.
  ///
  /// [stateDir] is an app-owned directory where Tailscale persists
  /// its node identity, keys, and profile data under a `tailscale/`
  /// subdirectory. The library creates that subdirectory as `0700` and the
  /// database as `0600`. The current implementation attempts to tighten
  /// pre-existing modes but logs and continues when chmod is unavailable; it
  /// does not yet provide application-layer StateStore encryption.
  /// On a fresh install this directory is empty; after the first
  /// successful [up], it contains credentials that let subsequent
  /// launches reconnect without an auth key.
  ///
  /// The current pre-launch SQLite StateStore is permission-protected but not
  /// encrypted at rest. It must not ship in a client application before the
  /// planned Keybay-backed encrypted StateStore cutover. Filesystem permissions
  /// and backup exclusion remain defense-in-depth after that cutover.
  ///
  /// Pick somewhere durable but **excluded from cloud backups** — the
  /// directory holds the node's WireGuard private key, and a key that
  /// leaks into iCloud/Google backups can be restored onto another
  /// device and silently impersonate this node. Prefer the application
  /// support directory (`getApplicationSupportDirectory()`) over the
  /// documents directory, which on iOS is included in iCloud backups
  /// and visible in the Files app, and on Android is reachable via
  /// Auto Backup. Mark the directory excluded from backup:
  /// `NSURLIsExcludedFromBackupKey` on iOS; `dataExtractionRules` /
  /// `fullBackupContent` rules on Android. For nodes that should not
  /// persist identity at all, register an ephemeral node instead.
  static void init({
    required String stateDir,
    TailscaleLogLevel logLevel = TailscaleLogLevel.silent,
  }) {
    if (stateDir.trim().isEmpty) {
      throw const TailscaleUsageException('stateDir must not be empty.');
    }
    try {
      ensurePosixFdTransportAvailable();
    } catch (error) {
      throw TailscaleUsageException(
        'POSIX fd transport is not available on this platform.',
        cause: error,
      );
    }

    final stateDirPtr = stateDir.toNativeUtf8();
    final resultPtr = native.duneConfigure(stateDirPtr, logLevel.nativeValue);
    try {
      final decoded = jsonDecode(resultPtr.toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw const TailscaleConfigurationException(
          'Native runtime returned an invalid initialization response.',
        );
      }
      final error = decoded['error'] as String?;
      if (error != null) {
        throw TailscaleConfigurationException(error);
      }
      final canonicalStateDir = decoded['stateDir'] as String?;
      if (canonicalStateDir == null || canonicalStateDir.isEmpty) {
        throw const TailscaleConfigurationException(
          'Native runtime did not return a canonical state directory.',
        );
      }
      _stateBaseDir = canonicalStateDir;
    } on TailscaleConfigurationException {
      rethrow;
    } catch (error) {
      throw TailscaleConfigurationException(
        'Failed to configure the native Tailscale runtime.',
        cause: error,
      );
    } finally {
      native.duneFree(resultPtr);
      calloc.free(stateDirPtr);
    }
  }

  /// Brings the embedded Tailscale node up and connects to the control
  /// plane — Tailscale's coordination service at
  /// `controlplane.tailscale.com`, or a self-hosted
  /// [Headscale](https://github.com/juanfont/headscale) if you set
  /// [controlUrl]. Registers the node on first launch, reconnects from
  /// persisted credentials on subsequent launches.
  ///
  /// [authKey] is required for first registration; get one from the
  /// tailnet admin panel at
  /// <https://login.tailscale.com/admin/settings/keys> (see
  /// <https://tailscale.com/kb/1085/auth-keys>). Reusable keys let you
  /// call [up] from multiple processes. Subsequent launches can omit it —
  /// the persisted session state reconnects automatically.
  ///
  /// Set [ephemeral] to register this process as a short-lived node. Ephemeral
  /// nodes are removed from the tailnet automatically after they go inactive
  /// by control-plane cleanup. Calling [logout] stops the local node and asks
  /// upstream Tailscale to remove the current profile, while preserving the
  /// lower-level StateStore container. Tailnet removal still follows the
  /// control plane's ephemeral-node cleanup behavior. Use this for CI jobs, preview
  /// environments, disposable tests, and other nodes whose identity should not
  /// outlive the process. This affects registration with the control plane; use
  /// a fresh or cleared `stateDir` passed to [Tailscale.init] when you need to
  /// force a new ephemeral identity.
  ///
  /// [hostname] sets the tailnet-visible hostname and the
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) label, so the
  /// node becomes reachable at `<hostname>.<tailnet>.ts.net`. Leave
  /// unset to let the embedded runtime pick the OS default.
  ///
  /// Resolves on the first **stable** state: `running`, `needsLogin`,
  /// or `needsMachineAuth`. This intentionally differs from Go's
  /// `tsnet.Server.Up`, which blocks only on `running` — a Dart app
  /// that needs to drive an in-app auth flow should not have to
  /// re-enter [up] just to see the [TailscaleStatus.authUrl]. Inspect
  /// the returned [TailscaleStatus.state] to decide what to do next:
  ///
  /// - `running` — ready; [http], [tcp], etc. are usable.
  /// - `needsLogin` — open [TailscaleStatus.authUrl] in a browser /
  ///   web view; the node finishes connecting after the user completes
  ///   the flow.
  /// - `needsMachineAuth` — authenticated but awaiting admin approval
  ///   on the control plane (
  ///   [device approval](https://tailscale.com/kb/1099/device-approval)).
  ///
  /// Transitions delivered via [onStateChange]:
  /// - First launch: `noState → starting → running`
  /// - Reconnect with persisted creds: `stopped → starting → running`
  /// - If creds are expired: `stopped → starting → needsLogin` (with
  ///   [TailscaleStatus.authUrl] populated)
  ///
  /// No-op when a runtime is already active with the same hostname, effective
  /// control URL, and ephemeral mode. An auth key never replaces an active
  /// identity; call [down] before changing runtime configuration.
  ///
  /// [timeout] bounds native startup and the stable-state wait. Once that
  /// deadline expires, the Future waits as long as required to establish
  /// fail-safe quarantine before returning, so total wall time can exceed
  /// [timeout] when native teardown is slow. A non-cancellable late native
  /// success is closed instead of becoming an unowned active node. Increase
  /// the timeout for slow mobile networks or self-hosted control planes.
  ///
  /// Throws [TailscaleUpException] if the node fails to start or reach a stable
  /// state before [timeout] (e.g. control plane unreachable). When no auth key
  /// or usable profile exists, upstream normally returns `needsLogin`.
  @override
  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    bool ephemeral = false,
    Uri? controlUrl,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _requireInitialized();
    if (timeout <= Duration.zero) {
      throw const TailscaleUsageException('up timeout must be positive.');
    }
    final validatedHostname = validateRuntimeHostname(hostname);
    final canonicalControlUrl = canonicalizeControlUrl(controlUrl);
    if (_nativeStartInFlight) {
      throw const TailscaleUpException(
        'Another node start is already in progress.',
        code: TailscaleErrorCode.lifecycleBusy,
      );
    }

    // Reserve the complete public startup synchronously, including recovery,
    // native construction, stable-state observation, and Dart capability
    // setup. Teardown operations share this supervisor queue.
    _nativeStartInFlight = true;
    final elapsed = Stopwatch()..start();
    try {
      return await _supervisorLifecycle.run(
        () => _runUp(
          hostname: validatedHostname,
          authKey: authKey ?? '',
          ephemeral: ephemeral,
          controlUrl: canonicalControlUrl,
          timeout: timeout,
          elapsed: elapsed,
        ),
      );
    } finally {
      _nativeStartInFlight = false;
    }
  }

  Future<TailscaleStatus> _runUp({
    required String hostname,
    required String authKey,
    required bool ephemeral,
    required String controlUrl,
    required Duration timeout,
    required Stopwatch elapsed,
  }) async {
    // Only count stable states that arrive AFTER start() returns. A prior
    // runtime's lingering emission must not satisfy a new construction.
    final stable = Completer<void>();
    var startReturned = false;
    NodeState? lastObservedState;
    final sub = onStateChange.listen((state) {
      if (!startReturned) return;
      lastObservedState = state;
      if (_isStableState(state) && !stable.isCompleted) {
        stable.complete();
      }
    });

    final requestToken = _allocateRuntimeToken();
    final workerExit = Completer<Object?>();
    _activeUpToken = requestToken;
    _activeUpWorkerExit = workerExit;

    Future<T> failOnWorkerExit<T>(Future<T> operation) {
      return Future.any<T>([
        operation,
        workerExit.future.then<T>(
          (cause) => throw TailscaleUpException(
            'The supervised worker terminated during node startup.',
            code: TailscaleErrorCode.workerTerminated,
            cause: cause,
          ),
        ),
      ]);
    }

    bool isWorkerTermination(Object error) =>
        error is TailscaleOperationException &&
        error.code == TailscaleErrorCode.workerTerminated;

    Duration remainingBudget() {
      final remaining = timeout - elapsed.elapsed;
      return remaining > Duration.zero ? remaining : Duration.zero;
    }

    Future<Never> timeoutAfterQuarantine({
      required String message,
      required Worker worker,
      required int token,
      required bool quarantine,
    }) async {
      if (quarantine) {
        try {
          await _quarantineTimedOutStart(worker, token);
        } catch (error) {
          throw TailscaleUpException(
            '$message Native quarantine could not be established.',
            code: TailscaleErrorCode.startupTimeout,
            cause: error,
          );
        }
      }
      throw TailscaleUpException(
        message,
        code: TailscaleErrorCode.startupTimeout,
      );
    }

    try {
      late final Worker worker;
      try {
        await _awaitWorkerRecovery().timeout(remainingBudget());
        if (remainingBudget() == Duration.zero) throw TimeoutException('');
        worker = _currentOrSpawnWorker();
      } on TimeoutException {
        throw TailscaleUpException(
          'Node startup could not begin within $timeout because an earlier '
          'runtime is still being quarantined.',
          code: TailscaleErrorCode.startupTimeout,
        );
      }

      final startFuture = worker.start(
        requestToken: requestToken,
        hostname: hostname,
        authKey: authKey,
        ephemeral: ephemeral,
        controlUrl: controlUrl,
      );

      late final WorkerStartResult startResult;
      try {
        startResult = await failOnWorkerExit(
          startFuture,
        ).timeout(remainingBudget());
      } on TimeoutException {
        return timeoutAfterQuarantine(
          message:
              'Node did not start within $timeout. The matching native '
              'generation was quarantined.',
          worker: worker,
          token: requestToken,
          quarantine: true,
        );
      }

      _activeUpToken = startResult.runtimeToken;

      _idleStatusError = null;
      if (!startResult.alreadyActive || _http == null) {
        _http?.close();
        _http = TailscaleHttpClient();
      }
      startReturned = true;

      // No-op up() case: the engine is already at a stable state and
      // won't emit another event. Check once post-start so we don't
      // wait on a state change that will never come.
      late final TailscaleStatus postStart;
      try {
        postStart = await failOnWorkerExit(status()).timeout(remainingBudget());
      } on TimeoutException {
        return timeoutAfterQuarantine(
          message: 'Node status did not respond within $timeout after startup.',
          worker: worker,
          token: startResult.runtimeToken,
          quarantine: !startResult.alreadyActive,
        );
      } catch (error, stackTrace) {
        if (isWorkerTermination(error)) {
          await _awaitWorkerRecovery();
        } else if (!startResult.alreadyActive) {
          await _quarantineTimedOutStart(worker, startResult.runtimeToken);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      lastObservedState = postStart.state;
      if (_isStableState(postStart.state) && !stable.isCompleted) {
        stable.complete();
      }

      try {
        await failOnWorkerExit(stable.future).timeout(remainingBudget());
      } on TimeoutException {
        return timeoutAfterQuarantine(
          message:
              'Node did not reach a stable state within $timeout '
              '(last observed: ${lastObservedState?.name ?? 'unknown'}). '
              'The matching native generation was quarantined.',
          worker: worker,
          token: startResult.runtimeToken,
          quarantine: !startResult.alreadyActive,
        );
      }

      try {
        return await failOnWorkerExit(status()).timeout(remainingBudget());
      } on TimeoutException {
        return timeoutAfterQuarantine(
          message:
              'Node reached a stable state but its final status did not '
              'respond within $timeout.',
          worker: worker,
          token: startResult.runtimeToken,
          quarantine: !startResult.alreadyActive,
        );
      } catch (error, stackTrace) {
        if (isWorkerTermination(error)) {
          await _awaitWorkerRecovery();
        } else if (!startResult.alreadyActive) {
          await _quarantineTimedOutStart(worker, startResult.runtimeToken);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      if (identical(_activeUpWorkerExit, workerExit)) {
        _activeUpWorkerExit = null;
        _activeUpToken = null;
      }
      await sub.cancel();
    }
  }

  static bool _isStableState(NodeState s) =>
      s == NodeState.running ||
      s == NodeState.needsLogin ||
      s == NodeState.needsMachineAuth;

  /// Returns the current node status — lifecycle state, assigned
  /// tailnet IPs, health warnings, and MagicDNS suffix. Node
  /// inventory is separate; call [nodes] when you need it.
  ///
  /// Safe to call before [up]. Before the encrypted-store cutover, an idle
  /// retained StateStore is conservatively reported as [NodeState.stopped]
  /// even after a confirmed logout; [NodeState.noState] requires an absent
  /// storage root. R4 replaces that filesystem probe with authenticated
  /// logical-state classification. This occupancy signal is not proof that
  /// the state is enrolled, valid, or sufficient to reconnect without a key.
  @override
  Future<TailscaleStatus> status() async {
    _requireInitialized();
    await _awaitWorkerRecovery();
    final classificationFailure = _idleStatusError;
    if (classificationFailure != null) throw classificationFailure;
    return _withWorker((worker) => worker.status());
  }

  /// Returns the current node inventory — every node on the tailnet
  /// this node is aware of, whether online right now or not.
  ///
  /// Separate from [status] so apps can poll lightweight node state
  /// without re-pulling the full node list on every refresh. For
  /// push-style updates, see [onNodeChanges].
  @override
  Future<List<TailscaleNode>> nodes() async {
    // async so a failed _requireInitialized() guard surfaces as a Future
    // rejection (catchable via .catchError / await), consistent with every
    // other lifecycle method, rather than throwing synchronously.
    _requireInitialized();
    return _snapshotNodes();
  }

  /// Returns the first known node with [ip] in its Tailscale IP list.
  ///
  /// This uses the same inventory snapshot as [nodes]. It returns null when
  /// the IP is unknown or the node has not appeared in the current netmap.
  @override
  Future<TailscaleNode?> nodeByIp(String ip) async {
    _requireInitialized();
    final target = ip.trim();
    if (target.isEmpty) return null;
    for (final node in await nodes()) {
      if (node.tailscaleIPs.contains(target)) return node;
    }
    return null;
  }

  Future<TailscaleNode?> _nodeByStableNodeId(String stableNodeId) async {
    final target = stableNodeId.trim();
    if (target.isEmpty) return null;
    for (final node in await nodes()) {
      if (node.stableNodeId == target) return node;
    }
    return null;
  }

  Future<TailscaleNode?> _currentExitNode() async {
    _requireInitialized();
    // LocalAPI exposes exit-node selection through prefs, while the public
    // API returns a full TailscaleNode. Resolve against a near-current node
    // snapshot; transient null is acceptable while netmap state catches up.
    final prefs = await _withWorker((worker) => worker.prefsGet());
    final nodeSnapshot = await nodes();

    for (final node in nodeSnapshot) {
      if (node.exitNode) return node;
    }

    final requestedId = prefs.exitNodeId;
    if (requestedId != null && requestedId.isNotEmpty) {
      for (final node in nodeSnapshot) {
        if (node.stableNodeId == requestedId) return node;
      }
    }

    return null;
  }

  Future<TailscaleNode?> _suggestExitNode() async {
    _requireInitialized();
    final nodeId = await _withWorker((worker) => worker.exitNodeSuggest());
    if (nodeId == null) return null;
    return _nodeByStableNodeId(nodeId);
  }

  /// Resolves a tailnet IP to the node's identity — stable node ID,
  /// owner login, hostname, and ACL tags — by querying the local
  /// LocalAPI.
  ///
  /// Returns null if [ip] is not known on the current tailnet.
  /// Useful for authorization decisions on incoming connections:
  /// combine with [tcp] `.bind(...)` and check
  /// [TailscaleNodeIdentity.tags] before handling. See
  /// <https://tailscale.com/kb/1068/tags> for the tag model.
  @override
  Future<TailscaleNodeIdentity?> whois(String ip) async {
    // async so the _requireInitialized() guard rejects the returned Future
    // instead of throwing synchronously (see nodes()).
    _requireInitialized();
    return _withWorker((worker) => worker.whois(ip));
  }

  /// Brings the embedded node down while preserving persisted credentials.
  @override
  Future<void> down() async {
    _requireInitialized();
    return _supervisorLifecycle.run(_runDown);
  }

  Future<void> _runDown() async {
    _reset();
    int? shutdownToken;
    try {
      var expectedRescue = false;
      late final WorkerCloseResult result;
      try {
        result = await _withWorker((worker) {
          shutdownToken = worker.runtimeToken;
          expectedRescue = shutdownToken != null;
          if (shutdownToken case final token?) {
            _shutdownIntents.add(token);
          }
          return worker.down();
        });
      } on TailscaleOperationException catch (error) {
        if (!expectedRescue ||
            error.code != TailscaleErrorCode.workerTerminated) {
          rethrow;
        }
        await _awaitWorkerRecoveryCompletion();
        final recovered = _recoveredShutdowns.remove(shutdownToken);
        if (recovered == null) {
          await _awaitWorkerRecovery();
          rethrow;
        }
        final recoveryError = recovered.error;
        if (recoveryError != null) {
          throw TailscaleOperationException(
            'down',
            recoveryError.message,
            code: recoveryError.code,
            statusCode: recoveryError.statusCode,
            cause: recoveryError,
          );
        }
        return;
      }
      if (result.started) {
        _publishTerminalNodes();
      }
      final closeError = result.error;
      if (closeError != null) {
        if (result.cleanupFailed ||
            closeError.code == TailscaleErrorCode.runtimeCleanupFailed) {
          _retainCleanupFailure(closeError);
        }
        throw closeError;
      }
      if (result.emitStopped) {
        _stateController.add(NodeState.stopped);
      }
    } finally {
      if (shutdownToken case final token?) {
        _shutdownIntents.remove(token);
        _recoveredShutdowns.remove(token);
      }
      // A preceding queued up() may have completed after the eager reset and
      // constructed Dart-side capabilities before this down reached native.
      _reset();
    }
  }

  /// Asks upstream Tailscale to revoke and remove the current logical profile.
  /// The lower-level StateStore container remains in place for later enrollment;
  /// physical storage destruction is a separate explicit local-reset concern.
  ///
  /// If the node was previously brought [down], logout temporarily reconstructs
  /// it from persisted state so revocation can still be attempted. A timeout or
  /// failure closes that possibly-mutated runtime, preserves local recovery
  /// evidence, and throws [TailscaleLogoutException] with
  /// [TailscaleErrorCode.logoutIndeterminate]. It never silently turns a failed
  /// remote logout into a local-only identity wipe.
  @override
  Future<void> logout() async {
    _requireInitialized();
    return _supervisorLifecycle.run(_runLogout);
  }

  Future<void> _runLogout() async {
    _reset();
    int? shutdownToken;
    try {
      final requestToken = _allocateRuntimeToken();
      var workerResponseReceived = false;
      try {
        final result = await _withWorker((worker) {
          shutdownToken = worker.runtimeToken ?? requestToken;
          _shutdownIntents.add(shutdownToken!);
          return worker.logout(requestToken: requestToken);
        });
        workerResponseReceived = true;
        _idleStatusError = null;
        final logoutError = result.error;
        if (result.started || result.noState) {
          _publishTerminalNodes();
        }
        if (result.cleanupFailed) {
          final cleanupFailure =
              logoutError?.code == TailscaleErrorCode.runtimeCleanupFailed
              ? logoutError!
              : TailscaleOperationException(
                  'logout',
                  'Logout did not cleanly close all native resources.',
                  code: TailscaleErrorCode.runtimeCleanupFailed,
                  cause: logoutError,
                );
          _retainCleanupFailure(cleanupFailure);
          if (logoutError != null) throw logoutError;
          throw cleanupFailure;
        }
        if (result.emitStopped) {
          _stateController.add(NodeState.stopped);
        }
        if (result.noState) {
          _stateController.add(NodeState.noState);
        }
        if (logoutError != null) throw logoutError;
      } on TailscaleLogoutException catch (error) {
        if (!workerResponseReceived &&
            (error.code == TailscaleErrorCode.workerTerminated ||
                error.code == TailscaleErrorCode.logoutIndeterminate)) {
          await _awaitWorkerRecoveryCompletion();
          final recovered = _recoveredShutdowns.remove(shutdownToken);
          if (recovered?.operation == 'logout') {
            final recoveryError = recovered?.error;
            if (recoveryError == null) return;
            throw TailscaleLogoutException(
              recoveryError.message,
              code: recoveryError.code,
              statusCode: recoveryError.statusCode,
              cause: recoveryError,
            );
          }
          final recoveryError = recovered?.error;
          if (recoveryError != null) {
            throw TailscaleLogoutException(
              recoveryError.message,
              code: recoveryError.code,
              statusCode: recoveryError.statusCode,
              cause: recoveryError,
            );
          }
          if (recovered == null) {
            await _awaitWorkerRecovery();
          }
        }
        rethrow;
      }
    } finally {
      if (shutdownToken case final token?) {
        _shutdownIntents.remove(token);
        _recoveredShutdowns.remove(token);
      }
      _reset();
    }
  }

  /// Terminates the supervised control isolate without touching native state.
  /// The caller-isolate rescue path must quarantine any matching runtime.
  @visibleForTesting
  Future<void> debugTerminateWorkerForTesting({bool expected = false}) async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    worker.debugTerminate(expected: expected);
  }

  /// Arms a test-only worker termination immediately after the next
  /// down/logout intent is tagged and before its native acknowledgement.
  @visibleForTesting
  Future<void> debugTerminateWorkerOnNextShutdownForTesting() async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    worker.debugTerminateOnNextShutdown();
  }

  /// Arms a test-only termination after the next native start response but
  /// before the public up operation can complete its stable-state wait.
  @visibleForTesting
  Future<void> debugTerminateWorkerAfterNextStartForTesting() async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    worker.debugTerminateAfterNextStart();
  }

  /// Arms a test-only termination immediately after the next logout command
  /// is sent to the worker, before its native acknowledgement reaches Dart.
  @visibleForTesting
  Future<void> debugTerminateWorkerAfterNextLogoutDispatchForTesting() async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    worker.debugTerminateAfterNextLogoutDispatch();
  }

  /// Terminates the worker after native down/logout has produced a terminal
  /// receipt but before that receipt can be delivered to the caller isolate.
  @visibleForTesting
  Future<void>
  debugTerminateWorkerAfterNextLifecycleNativeResultForTesting() async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    worker.debugTerminateAfterNextLifecycleNativeResult();
  }
}
