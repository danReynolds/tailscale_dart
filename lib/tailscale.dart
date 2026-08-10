import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;

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
import 'src/keybay_state_custody.dart';
import 'src/runtime_config.dart';
import 'src/state_custody_coordinator.dart';
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
        ServeForwardResult,
        ServeForwardFn,
        ServeCloseFn,
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
export 'src/worker/worker.dart' show DebugTerminatePoint;

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

/// Which already-thrown exceptions may stand in unchanged for a site's
/// cleanup failure in [Tailscale._retainedCleanupFailure], instead of being
/// wrapped in that site's fresh `runtimeCleanupFailed` exception.
enum _CleanupFailureKeep { none, anyOperationException, cleanupCoded }

final class _TailscaleInitialization {
  const _TailscaleInitialization({
    required this.canonicalStateBaseDir,
    required this.logLevel,
    required this.keybay,
  });

  final String canonicalStateBaseDir;
  final TailscaleLogLevel logLevel;
  final KeybayStateCustodyBinding keybay;

  bool hasSameIdentity(_TailscaleInitialization other) =>
      canonicalStateBaseDir == other.canonicalStateBaseDir &&
      logLevel == other.logLevel &&
      keybay.hostAppId == other.keybay.hostAppId &&
      keybay.keybayNamespace == other.keybay.keybayNamespace;
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
  Future<void> forgetLocalIdentity();
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

  static _TailscaleInitialization? _initialization;

  pkg_http.Client? _http;
  List<TailscaleNode>? _latestNodes;
  bool _nativeStartInFlight = false;
  // Completes when an in-flight public start settles. Captured synchronously
  // by identity-bound calls that found no runtime, so they can join that
  // start instead of failing stale. Never completes with an error.
  Future<void>? _nativeStartPending;
  Worker? _workerInstance;
  Future<void>? _workerRecovery;
  TailscaleOperationException? _workerRecoveryFailure;
  TailscaleStatusException? _idleStatusError;
  final Set<int> _shutdownIntents = <int>{};
  final Map<int, RuntimeQuarantineResult> _recoveredShutdowns =
      <int, RuntimeQuarantineResult>{};
  int _nextRuntimeToken = 1;
  final LifecycleQueue _supervisorLifecycle = LifecycleQueue();
  final StateCustodyCoordinator _stateCustody = StateCustodyCoordinator();
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

  static void _requireInitialized() {
    if (_initialization == null) {
      throw const TailscaleUsageException(
        'Call Tailscale.init(stateDir: ..., appId: ...) before using '
        'Tailscale.instance.',
      );
    }
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
    onRuntimeTerminated: _handleNativeRuntimeTermination,
    onExit: _handleWorkerExit,
  );

  void _handleNativeRuntimeTermination(
    Worker worker,
    int runtimeToken,
    TailscaleOperationException failure,
    bool emitStopped,
    bool cleanupFailed,
    bool reportRuntimeError,
  ) {
    if (!identical(_workerInstance, worker)) return;

    _reset();
    _publishTerminalNodes();
    if (reportRuntimeError) {
      _errorController.add(
        TailscaleRuntimeError(
          message: failure.message,
          code: switch (failure.code) {
            TailscaleErrorCode.publicationBootstrapFailure =>
              TailscaleRuntimeErrorCode.publicationBootstrapFailure,
            TailscaleErrorCode.publicationCommitIndeterminate =>
              TailscaleRuntimeErrorCode.publicationDeliveryFailure,
            _ => TailscaleRuntimeErrorCode.unknown,
          },
        ),
      );
    }
    if (cleanupFailed) {
      _retainedCleanupFailure(
        failure,
        operation: 'native runtime termination',
        message: 'Native teardown did not reach a proven quiescent state.',
        keep: _CleanupFailureKeep.none,
      );
      return;
    }

    _idleStatusError = null;
    if (emitStopped) _stateController.add(NodeState.stopped);
  }

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

  Future<T> _withNativeRuntime<T>(
    Future<T> Function(int runtimeToken) operation,
  ) {
    // Capture synchronously, before recovery or the offload semaphore can
    // yield. A queued operation authorized by runtime A must never discover
    // and mutate a replacement runtime B when it finally enters native code.
    final worker = _workerInstance;
    final runtimeToken = worker != null && !worker.isDisposed
        ? worker.runtimeToken ?? 0
        : 0;
    // A zero token means no runtime existed at capture time, so there is no
    // earlier generation this call could be rebound away from. If a start is
    // settling, join it and re-capture: the worker FIFO used to queue these
    // calls behind that start, and failing them stale instead would break
    // the gate-phase error contract for anything issued during up().
    final pendingStart = runtimeToken == 0 ? _nativeStartPending : null;
    return () async {
      await _awaitWorkerRecovery();
      if (pendingStart == null) return await operation(runtimeToken);
      await pendingStart;
      final started = _workerInstance;
      return await operation(
        started != null && !started.isDisposed ? started.runtimeToken ?? 0 : 0,
      );
    }();
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
    final recoveryToken = runtimeToken ?? _activeUpToken;
    final activeUpExit = _activeUpWorkerExit;
    if (_activeUpToken != null &&
        activeUpExit != null &&
        !activeUpExit.isCompleted) {
      activeUpExit.complete(cause);
    }
    _reset();
    _trackWorkerRecovery(
      () => _recoverExitedWorker(
        runtimeToken: recoveryToken,
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
      if (quarantine.custodyHeld) {
        await _stateCustody.settleAbandonment(
          token: quarantine.token,
          disposition: quarantine.custodyDisposition,
        );
      } else {
        // Quarantine is authoritative after a worker response is lost. If
        // native custody is already terminal, retire the matching caller-side
        // session as well so its DEK buffers cannot remain retained.
        await _stateCustody.discardTerminalSession(quarantine.token);
      }
      final quarantineError = quarantine.error;
      final hasTerminalReceipt = quarantine.operation != null;
      if (!hasTerminalReceipt && quarantineError != null) {
        throw quarantineError;
      }
      if (!hasTerminalReceipt && quarantine.pending) {
        await awaitNativeRuntimeQuiescence(token);
      }
      if (hasTerminalReceipt && quarantine.cleanupFailed) {
        _retainedCleanupFailure(
          quarantineError,
          operation: 'worker recovery',
          message:
              'The completed lifecycle operation did not cleanly close '
              'all native resources.',
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

    // The worker is gone, so no command that had not already entered native
    // code can do so later. An entry call already in Go remains registered and
    // retires its own tombstone on return.
    try {
      await retireNativeAbandonedRuntimeToken(runtimeToken ?? 0);
    } catch (error) {
      rescueFailure ??= error;
      _workerRecoveryFailure ??= TailscaleOperationException(
        'worker recovery',
        'Failed to retire an abandoned native dispatch token.',
        code: TailscaleErrorCode.workerTerminated,
        cause: error,
      );
    }

    final hasTerminalReceipt = quarantine?.operation != null;
    TailscaleStatus? idleStatus;
    if (rescueFailure == null && !hasTerminalReceipt) {
      // A runtime that was already active authenticated its Store before
      // publication, so its successful quarantine can truthfully publish the
      // stopped transition without a second Keybay read. Preparations that
      // never published emit nothing; the next explicit status() performs a
      // fresh secure idle probe on the caller isolate.
      if (quarantine?.started == true) {
        idleStatus = TailscaleStatus.stopped;
      }
      _idleStatusError = null;
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
        if (cause != null) 'The worker reported an exit cause.',
        if (rescueFailure != null) 'Native quarantine failed.',
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

  /// Classifies one failed-cleanup [error], retains it via
  /// [_retainCleanupFailure], and returns the retained failure so the call
  /// site can throw its operation-specific exception with restart advice.
  ///
  /// [keep] preserves each site's pass-through predicate; anything that does
  /// not qualify is wrapped in a fresh
  /// [TailscaleErrorCode.runtimeCleanupFailed] exception built from
  /// [operation] and [message] with [error] as its cause.
  TailscaleOperationException _retainedCleanupFailure(
    Object? error, {
    required String operation,
    required String message,
    _CleanupFailureKeep keep = _CleanupFailureKeep.cleanupCoded,
  }) {
    final kept = switch (keep) {
      _CleanupFailureKeep.none => null,
      _CleanupFailureKeep.anyOperationException =>
        error is TailscaleOperationException ? error : null,
      _CleanupFailureKeep.cleanupCoded =>
        error is TailscaleOperationException &&
                error.code == TailscaleErrorCode.runtimeCleanupFailed
            ? error
            : null,
    };
    final failure =
        kept ??
        TailscaleOperationException(
          operation,
          message,
          code: TailscaleErrorCode.runtimeCleanupFailed,
          cause: error,
        );
    _retainCleanupFailure(failure);
    return failure;
  }

  Future<RuntimeQuarantineResult> _quarantineStateOperation(int token) async {
    final result = await quarantineNativeRuntime(token);
    // Custody must settle before interpreting any accompanying native error;
    // otherwise an error response can strand the lease and possibly-committed
    // Keybay write indefinitely.
    if (result.custodyHeld) {
      await _stateCustody.settleAbandonment(
        token: result.token,
        disposition: result.custodyDisposition,
      );
    } else {
      // Native quarantine is the authority for response-loss ambiguity. If it
      // proves custody is already terminal, retire any caller-side session
      // whose CompletePersistentCustody response was lost.
      await _stateCustody.discardTerminalSession(result.token);
    }
    if (result.pending) {
      await awaitNativeRuntimeQuiescence(token);
    }
    final quarantineError = result.error;
    if (quarantineError != null) throw quarantineError;
    return result;
  }

  void _retireAbandonedTokenAfter(
    Future<Object?> originatingOperation,
    int token,
  ) {
    unawaited(() async {
      try {
        await originatingOperation;
      } catch (_) {
        // Settlement, not success, is the retirement precondition.
      }
      try {
        await retireNativeAbandonedRuntimeToken(token);
      } catch (error) {
        _errorController.add(
          TailscaleRuntimeError(
            message: 'An abandoned native dispatch token could not be retired.',
            code: TailscaleRuntimeErrorCode.worker,
          ),
        );
      }
    }());
  }

  Future<void> _quarantineTimedOutStart(
    Worker worker,
    int token, {
    Future<Object?>? originatingOperation,
  }) async {
    worker.detachRuntimeToken(token);

    final quarantined = Completer<void>();
    _trackWorkerRecovery(() async {
      try {
        final result = await _quarantineStateOperation(token);
        if (result.matched) {
          _reset();
        }
        // An idempotent up() can time out before receiving the existing
        // runtime token. Quarantining its request token correctly matches
        // nothing; do not reset, classify, or republish that live runtime.
        if (result.matched) {
          _idleStatusError = null;
          if (result.emitStopped) {
            _stateController.add(NodeState.stopped);
          }
        }
        // This completes only after the native operation, late custody, and
        // quiescence barrier have all settled.
        if (!quarantined.isCompleted) quarantined.complete();
      } catch (error, stackTrace) {
        _reset();
        final cleanupFailure = _retainedCleanupFailure(
          error,
          operation: 'worker recovery',
          message:
              'Timed-out startup cleanup did not reach a proven quiescent '
              'state.',
          keep: _CleanupFailureKeep.none,
        );
        if (!quarantined.isCompleted) {
          quarantined.completeError(cleanupFailure, stackTrace);
        }
      }
    });
    await quarantined.future;
    if (originatingOperation != null) {
      _retireAbandonedTokenAfter(originatingOperation, token);
    }
  }

  /// Runs the shared persistent preparation sequence for [token].
  ///
  /// Returns true when a prepared runtime remains open for a subsequent
  /// start; false when the preparation already settled as an authenticated
  /// no-state idle result and was closed.
  Future<bool> _preparePersistentState({
    required int token,
    required bool startRequested,
  }) async {
    var nativeAdmission = false;
    try {
      await beginNativePersistentPreparation(token);
      nativeAdmission = true;
      final layout = await inspectNativePersistentPreparation(token);
      if (layout != 'absent' && layout != 'encrypted') {
        throw TailscaleOperationException(
          'state preparation',
          'Native returned an unsupported persistent-state layout.',
          code: TailscaleErrorCode.invalidStateFormat,
        );
      }

      final initialization = _initialization!;
      final session = await _stateCustody.begin(
        token: token,
        binding: initialization.keybay,
      );
      final existingDek = await session.readDek();
      final action = await resolveNativePersistentCustody(
        token,
        dekPresent: existingDek != null,
      );

      if (action == 'provision' && !startRequested) {
        await _stateCustody.complete(token);
        await finishNativePreparedPersistentState(token);
        return false;
      }

      if (action == 'provision') {
        final freshDek = await session.writeFreshDek(generateStateStoreDek());
        supplyTransferredDekToNative(
          token: token,
          transferred: session.transferDek(freshDek),
        );
      } else if (action == 'open' && existingDek != null) {
        supplyTransferredDekToNative(
          token: token,
          transferred: session.transferDek(existingDek),
        );
      } else {
        throw TailscaleOperationException(
          'state preparation',
          'Native returned an inconsistent persistent-state action.',
          code: TailscaleErrorCode.invalidStateFormat,
        );
      }

      final empty = await prepareNativePersistentState(token);
      await _stateCustody.complete(token);
      if (action == 'open' && empty && !startRequested) {
        await finishNativePreparedPersistentState(token);
        return false;
      }
      return true;
    } catch (error, stackTrace) {
      Object? cleanupError;
      if (nativeAdmission) {
        try {
          await _quarantineStateOperation(token);
          await retireNativeAbandonedRuntimeToken(token);
        } catch (cleanup) {
          cleanupError = cleanup;
        }
      }
      if (cleanupError != null) {
        throw TailscaleOperationException(
          'state preparation',
          'Persistent state preparation failed and its cleanup could not be '
              'confirmed. Restart the process before retrying.',
          code: TailscaleErrorCode.runtimeCleanupFailed,
          cause: (operation: error, cleanup: cleanupError),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
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
      (runtimeToken) => offloadTcpDial(
        runtimeToken: runtimeToken,
        host: host,
        port: port,
        timeout: timeout,
      ),
    ),
    // Offloaded like dial: bind admission joins the native first-`Up`
    // bootstrap, which must not park the worker FIFO.
    listenFn: (tailnetPort, tailnetHost) => _withNativeRuntime(
      (runtimeToken) => offloadTcpListenFd(
        runtimeToken: runtimeToken,
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
      ),
    ),
    closeListenerFn: (listenerId) =>
        _withWorker((worker) => worker.closeFdListener(listenerId: listenerId)),
  );
  @override
  late final Tls tls = createTls(
    listenFn: (tailnetPort, tailnetHost) => _withNativeRuntime(
      (runtimeToken) => offloadTlsListenFd(
        runtimeToken: runtimeToken,
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
    bindFn: (host, port) => _withNativeRuntime(
      (runtimeToken) =>
          offloadUdpBindFd(runtimeToken: runtimeToken, host: host, port: port),
    ),
    defaultAddressFn: () async => (await status()).ipv4,
    closeFn: (bindingId) =>
        _withWorker((worker) => worker.udpCloseBinding(bindingId: bindingId)),
  );

  /// One worker wiring shared verbatim by [serve] and [funnel]; the two
  /// factories differ only in the namespace they expose, with every closure
  /// selecting Serve or Funnel behavior from its own `funnel` argument.
  late final ({ServeForwardFn forward, ServeClearFn clear, ServeCloseFn close})
  _publicationWiring = (
    forward:
        ({
          required tailnetPort,
          required localPort,
          required localAddress,
          required path,
          required https,
          required funnel,
        }) => _withNativeRuntime(
          (runtimeToken) => offloadServeForward(
            runtimeToken: runtimeToken,
            tailnetPort: tailnetPort,
            localPort: localPort,
            localAddress: localAddress,
            path: path,
            https: https,
            funnel: funnel,
          ),
        ),
    clear: ({required tailnetPort, required path, required funnel}) =>
        _withWorker(
          (worker) => worker.serveClear(
            tailnetPort: tailnetPort,
            path: path,
            funnel: funnel,
          ),
        ),
    close:
        ({
          required tailnetPort,
          required path,
          required funnel,
          required generation,
          required mappingToken,
        }) => _withWorker(
          (worker) => worker.serveClose(
            tailnetPort: tailnetPort,
            path: path,
            funnel: funnel,
            generation: generation,
            mappingToken: mappingToken,
          ),
        ),
  );
  @override
  late final Funnel funnel = createFunnel(
    forwardFn: _publicationWiring.forward,
    clearFn: _publicationWiring.clear,
    closeFn: _publicationWiring.close,
  );
  @override
  late final Http http = createHttp(
    clientGetter: () => _http,
    bindFn: (port) => _withNativeRuntime(
      (runtimeToken) =>
          offloadHttpBind(runtimeToken: runtimeToken, tailnetPort: port),
    ),
    closeBindingFn: (bindingId) =>
        _withWorker((worker) => worker.httpCloseBinding(bindingId: bindingId)),
  );

  // ─── Feature namespaces ─────────────────────────────────────────────
  @override
  final Taildrop taildrop = Taildrop.instance;
  @override
  late final Serve serve = createServe(
    forwardFn: _publicationWiring.forward,
    clearFn: _publicationWiring.clear,
    closeFn: _publicationWiring.close,
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
      (runtimeToken) => offloadDiagPing(
        runtimeToken: runtimeToken,
        ip: ip,
        timeout: timeout,
        pingType: type.name,
      ),
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
  /// [appId] is the embedding application's stable identifier, such as its
  /// reverse-DNS bundle or application ID. Tailscale reserves the dedicated
  /// `<appId>.tailscale` Keybay namespace for the StateStore encryption key.
  /// It must remain unchanged for the lifetime of [stateDir]. Constructing
  /// this binding does not access Keybay; secure-state lifecycle operations
  /// resolve it lazily.
  ///
  /// [stateDir] is the app-owned base directory for persistent package state.
  /// The logical Tailscale StateStore is one authenticated encrypted file under
  /// its owner-only `tailscale/` subtree. One random 32-byte DEK is held by
  /// Keybay and retained in memory for the runtime lifetime. Missing custody,
  /// unsafe paths or permissions, tampering, and pre-launch SQLite/FileStore
  /// layouts fail closed; legacy identities are not migrated. After the first
  /// successful persistent [up], later launches can reconnect without an auth
  /// key.
  ///
  /// This encrypts StateStore data, not the entire subtree. Upstream logs, log
  /// configuration, and TLS/certificate sidecars can remain outside that
  /// encryption boundary. Owner-only permissions and backup exclusion are
  /// therefore still required.
  ///
  /// Pick a durable application-support directory, not a user documents
  /// directory, and exclude it from cloud backup. Mark the directory excluded:
  /// `NSURLIsExcludedFromBackupKey` on iOS; `dataExtractionRules` /
  /// `fullBackupContent` rules on Android. Persistent Android nodes require API
  /// 31+; persistent Linux nodes require desktop `secret-tool` and an available,
  /// unlocked Secret Service. Older Android and headless Linux can use explicit
  /// ephemeral mode, which uses an in-memory StateStore and never accesses
  /// Keybay.
  static void init({
    required String stateDir,
    required String appId,
    TailscaleLogLevel logLevel = TailscaleLogLevel.silent,
  }) {
    if (stateDir.trim().isEmpty) {
      throw const TailscaleUsageException('stateDir must not be empty.');
    }
    final custody = KeybayStateCustodyBinding(hostAppId: appId);
    try {
      ensurePosixFdTransportAvailable();
    } catch (error) {
      throw TailscaleUsageException(
        'POSIX fd transport is not available on this platform.',
        cause: error,
      );
    }

    final stateDirPtr = stateDir.toNativeUtf8();
    final keybayNamespacePtr = custody.keybayNamespace.toNativeUtf8();
    final resultPtr = native.duneConfigure(
      stateDirPtr,
      keybayNamespacePtr,
      logLevel.nativeValue,
    );
    // Ephemeral scratch must live in a platform-writable temporary location.
    // Dart resolves the app's real one (Go's os.TempDir() fallback is not
    // app-writable on Android); native ignores empty and repeated values.
    final scratchParentPtr = Directory.systemTemp.path.toNativeUtf8();
    try {
      native.duneSetEphemeralScratchParent(scratchParentPtr);
    } finally {
      calloc.free(scratchParentPtr);
    }
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
      final candidate = _TailscaleInitialization(
        canonicalStateBaseDir: canonicalStateDir,
        logLevel: logLevel,
        keybay: custody,
      );
      final configured = _initialization;
      if (configured == null) {
        _initialization = candidate;
      } else if (!configured.hasSameIdentity(candidate)) {
        throw const TailscaleConfigurationException(
          'Native and Dart Tailscale initialization identities diverged.',
        );
      }
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
      calloc.free(keybayNamespacePtr);
    }
  }

  /// Brings the embedded Tailscale node up and connects to the control
  /// plane — Tailscale's coordination service at
  /// `controlplane.tailscale.com`, or a self-hosted
  /// [Headscale](https://github.com/juanfont/headscale) if you set
  /// [controlUrl]. Registers the node on first launch, reconnects from
  /// persisted credentials on subsequent launches.
  ///
  /// [authKey] can enroll a fresh persistent node without user interaction;
  /// get one from the tailnet admin panel at
  /// <https://login.tailscale.com/admin/settings/keys> (see
  /// <https://tailscale.com/kb/1085/auth-keys>). Reusable keys let you
  /// call [up] from multiple processes. It is optional in persistent mode:
  /// without a usable profile or key, upstream enters [NodeState.needsLogin]
  /// and returns an authorization URL for interactive enrollment. Subsequent
  /// launches can omit it because persisted session state reconnects.
  ///
  /// Set [ephemeral] to register this process as a short-lived node. Ephemeral
  /// nodes are removed from the tailnet automatically after they go inactive
  /// by control-plane cleanup. Calling [logout] stops the local node and asks
  /// upstream Tailscale to remove the current profile, while preserving the
  /// lower-level StateStore container. Tailnet removal still follows the
  /// control plane's ephemeral-node cleanup behavior. Use this for CI jobs, preview
  /// environments, disposable tests, and other nodes whose identity should not
  /// outlive the process. Ephemeral mode retains no local identity: every new
  /// [up] after [down] (or process restart) needs a valid auth key, and a
  /// single-use key must be replaced. The configured `stateDir` is used only
  /// for admission/coordination and does not need to be cleared.
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
    if (ephemeral && (authKey == null || authKey.isEmpty)) {
      throw const TailscaleUsageException(
        'ephemeral up requires a non-empty authKey.',
      );
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
    final startSettled = Completer<void>();
    _nativeStartPending = startSettled.future;
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
      _nativeStartPending = null;
      startSettled.complete();
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
    var pendingNativeToken = false;
    Future<WorkerStartResult>? originatingStart;
    Worker? settledWorker;
    int? settledRuntimeToken;
    int? bootstrapFailureToken;
    Future<TailscaleOperationException>? publicationBootstrapFailure;

    Future<T> failOnWorkerExit<T>(Future<T> operation) {
      final futures = <Future<T>>[
        operation,
        workerExit.future.then<T>(
          (cause) => throw TailscaleUpException(
            'The supervised worker terminated during node startup.',
            code: TailscaleErrorCode.workerTerminated,
            cause: cause,
          ),
        ),
      ];
      final fatal = publicationBootstrapFailure;
      if (fatal != null) {
        futures.add(fatal.then<T>((failure) => throw failure));
      }
      return Future.any<T>(futures);
    }

    bool isWorkerTermination(Object error) =>
        error is TailscaleOperationException &&
        error.code == TailscaleErrorCode.workerTerminated;

    bool isPublicationBootstrapFailure(Object error) =>
        error is TailscaleOperationException &&
        error.code == TailscaleErrorCode.publicationBootstrapFailure;

    Duration remainingBudget() {
      final remaining = timeout - elapsed.elapsed;
      return remaining > Duration.zero ? remaining : Duration.zero;
    }

    Future<Never> timeoutAfterQuarantine({
      required String message,
      required Worker worker,
      required int token,
      required bool quarantine,
      Future<Object?>? originatingOperation,
    }) async {
      if (quarantine) {
        try {
          await _quarantineTimedOutStart(
            worker,
            token,
            originatingOperation: originatingOperation,
          );
          pendingNativeToken = false;
        } catch (error) {
          final cleanupFailure = _retainedCleanupFailure(
            error,
            operation: 'up',
            message: 'Native startup quarantine could not be confirmed.',
            keep: _CleanupFailureKeep.anyOperationException,
          );
          throw TailscaleUpException(
            '$message Native cleanup could not be confirmed; restart before '
            'retrying.',
            code: TailscaleErrorCode.runtimeCleanupFailed,
            cause: cleanupFailure,
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
      } on TimeoutException {
        throw TailscaleUpException(
          'Node startup could not begin within $timeout because an earlier '
          'runtime is still being quarantined.',
          code: TailscaleErrorCode.startupTimeout,
        );
      }

      final currentWorker = _workerInstance;
      final activeRuntime =
          currentWorker != null &&
          !currentWorker.isDisposed &&
          currentWorker.runtimeToken != null;
      if (!ephemeral && !activeRuntime) {
        late final bool startPrepared;
        final preparationOperation = _preparePersistentState(
          token: requestToken,
          startRequested: true,
        );
        try {
          startPrepared = await preparationOperation.timeout(remainingBudget());
        } on TimeoutException {
          _retireAbandonedTokenAfter(preparationOperation, requestToken);
          try {
            await _quarantineStateOperation(requestToken);
          } catch (cleanupError) {
            final cleanupFailure = _retainedCleanupFailure(
              cleanupError,
              operation: 'up',
              message: 'Persistent state cleanup could not be confirmed.',
              keep: _CleanupFailureKeep.anyOperationException,
            );
            throw TailscaleUpException(
              'Persistent state preparation exceeded $timeout and cleanup '
              'could not be confirmed; restart before retrying.',
              code: TailscaleErrorCode.runtimeCleanupFailed,
              cause: cleanupFailure,
            );
          }
          throw TailscaleUpException(
            'Persistent state preparation exceeded $timeout. The matching '
            'operation was quarantined.',
            code: TailscaleErrorCode.startupTimeout,
          );
        }
        if (!startPrepared) {
          _idleStatusError = null;
          return TailscaleStatus.noState;
        }
        pendingNativeToken = true;
      }

      worker = _currentOrSpawnWorker();
      settledWorker = worker;
      final failureToken = worker.runtimeToken ?? requestToken;
      bootstrapFailureToken = failureToken;
      publicationBootstrapFailure = worker.publicationBootstrapFailureFor(
        failureToken,
      );
      _activeUpToken = requestToken;
      _activeUpWorkerExit = workerExit;

      pendingNativeToken = true;
      final startFuture = worker.start(
        requestToken: requestToken,
        hostname: hostname,
        authKey: authKey,
        ephemeral: ephemeral,
        controlUrl: controlUrl,
        bootstrapBudget: remainingBudget(),
      );
      originatingStart = startFuture;

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
          originatingOperation: startFuture,
        );
      }
      pendingNativeToken = false;
      settledRuntimeToken = startResult.runtimeToken;

      _activeUpToken = startResult.runtimeToken;

      _idleStatusError = null;
      if (!startResult.alreadyActive || _http == null) {
        _http?.close();
        _http = TailscaleHttpClient(runtimeToken: startResult.runtimeToken);
      }
      startReturned = true;

      // No-op up() case: the engine is already at a stable state and
      // won't emit another event. Check once post-start so we don't
      // wait on a state change that will never come.
      late final TailscaleStatus postStart;
      try {
        postStart = await failOnWorkerExit(
          worker.status(),
        ).timeout(remainingBudget());
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
        } else if (!isPublicationBootstrapFailure(error) &&
            !startResult.alreadyActive) {
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
        return await failOnWorkerExit(
          worker.status(),
        ).timeout(remainingBudget());
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
        } else if (!isPublicationBootstrapFailure(error) &&
            !startResult.alreadyActive) {
          await _quarantineTimedOutStart(worker, startResult.runtimeToken);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } catch (error, stackTrace) {
      Object? cleanupError;
      if (isPublicationBootstrapFailure(error)) {
        // Native already detached and drained this exact generation before
        // publishing the terminal event. Do not run startup quarantine again.
        pendingNativeToken = false;
      }
      if (pendingNativeToken) {
        _workerInstance?.detachRuntimeToken(requestToken);
        if (isWorkerTermination(error)) {
          try {
            await _awaitWorkerRecoveryCompletion();
            await _awaitWorkerRecovery();
          } catch (recoveryError) {
            cleanupError = recoveryError;
          }
        }
        if (cleanupError == null) {
          try {
            await _quarantineStateOperation(requestToken);
            pendingNativeToken = false;
            final operation = originatingStart;
            if (operation != null && !isWorkerTermination(error)) {
              _retireAbandonedTokenAfter(operation, requestToken);
            } else if (operation == null) {
              await retireNativeAbandonedRuntimeToken(requestToken);
            }
          } catch (quarantineError) {
            cleanupError = quarantineError;
          }
        }
      }
      if (cleanupError != null) {
        final cleanupFailure = _retainedCleanupFailure(
          cleanupError,
          operation: 'up',
          message:
              'Failed startup cleanup did not reach a proven quiescent '
              'state.',
        );
        throw TailscaleUpException(
          'Node startup failed and native cleanup could not be confirmed; '
          'restart before retrying.',
          code: TailscaleErrorCode.runtimeCleanupFailed,
          cause: (operation: error, cleanup: cleanupFailure),
        );
      }
      if (error is TailscaleUpException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (error is TailscaleOperationException) {
        Error.throwWithStackTrace(
          TailscaleUpException(
            error.message,
            code: error.code,
            statusCode: error.statusCode,
            cause: error,
          ),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(
        TailscaleUpException('Node startup failed.', cause: error),
        stackTrace,
      );
    } finally {
      final token = settledRuntimeToken;
      if (token != null) {
        // Linearize the public Future settlement with a possible later first
        // Running observation. This synchronous native marker happens before
        // `up()` returns to the host application.
        settledWorker?.markUpSettled(token);
      }
      final failureToken = bootstrapFailureToken;
      if (failureToken != null) {
        settledWorker?.retirePublicationBootstrapFailure(failureToken);
      }
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
  /// Safe to call before [up]. Idle persistent state is authenticated with the
  /// installation DEK from Keybay: an absent or authenticated-empty Store is
  /// [NodeState.noState], while authenticated logical state is
  /// [NodeState.stopped]. Missing/orphaned keys, malformed state, and locked
  /// secure storage fail closed instead of being reported as a fresh node.
  @override
  Future<TailscaleStatus> status() async {
    _requireInitialized();
    await _awaitWorkerRecovery();
    final classificationFailure = _idleStatusError;
    if (classificationFailure != null) throw classificationFailure;
    final current = _workerInstance;
    if (current != null &&
        !current.isDisposed &&
        current.runtimeToken != null) {
      return current.status();
    }
    return _supervisorLifecycle.run(_runIdleSecureStatus);
  }

  Future<TailscaleStatus> _runIdleSecureStatus() async {
    await _awaitWorkerRecovery();
    final current = _workerInstance;
    if (current != null &&
        !current.isDisposed &&
        current.runtimeToken != null) {
      return current.status();
    }

    final token = _allocateRuntimeToken();
    var pendingPreparation = false;
    try {
      final startPrepared = await _preparePersistentState(
        token: token,
        startRequested: false,
      );
      if (!startPrepared) return TailscaleStatus.noState;
      pendingPreparation = true;
      await finishNativePreparedPersistentState(token);
      pendingPreparation = false;
      return TailscaleStatus.stopped;
    } catch (error, stackTrace) {
      Object? cleanupError;
      if (pendingPreparation) {
        try {
          await _quarantineStateOperation(token);
          await retireNativeAbandonedRuntimeToken(token);
          pendingPreparation = false;
        } catch (cleanup) {
          cleanupError = cleanup;
        }
      }
      if (cleanupError != null) {
        final cleanupFailure = _retainedCleanupFailure(
          cleanupError,
          operation: 'status',
          message:
              'Persistent status cleanup did not reach a proven quiescent '
              'state.',
          keep: _CleanupFailureKeep.none,
        );
        throw TailscaleStatusException(
          'Persistent state inspection failed and cleanup could not be '
          'confirmed; restart before retrying.',
          code: TailscaleErrorCode.runtimeCleanupFailed,
          cause: (operation: error, cleanup: cleanupFailure),
        );
      }
      if (error is TailscaleStatusException) rethrow;
      if (error is TailscaleOperationException) {
        Error.throwWithStackTrace(
          TailscaleStatusException(
            error.message,
            code: error.code,
            statusCode: error.statusCode,
            cause: error,
          ),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(
        TailscaleStatusException(
          'Persistent node state could not be authenticated.',
          cause: error,
        ),
        stackTrace,
      );
    }
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
    var pendingPersistentPreparation = false;
    final requestToken = _allocateRuntimeToken();
    try {
      var workerResponseReceived = false;
      try {
        final current = _workerInstance;
        final activeRuntime =
            current != null &&
            !current.isDisposed &&
            current.runtimeToken != null;
        if (!activeRuntime) {
          try {
            final startPrepared = await _preparePersistentState(
              token: requestToken,
              startRequested: false,
            );
            if (!startPrepared) {
              _idleStatusError = null;
              _publishTerminalNodes();
              _stateController.add(NodeState.noState);
              return;
            }
            pendingPersistentPreparation = true;
          } on TailscaleOperationException catch (error) {
            throw TailscaleLogoutException(
              error.message,
              code: error.code,
              statusCode: error.statusCode,
              cause: error,
            );
          }
        }
        final result = await _withWorker((worker) {
          shutdownToken = worker.runtimeToken ?? requestToken;
          _shutdownIntents.add(shutdownToken!);
          return worker.logout(requestToken: requestToken);
        });
        workerResponseReceived = true;
        pendingPersistentPreparation = false;
        _idleStatusError = null;
        final logoutError = result.error;
        if (result.started || result.noState) {
          _publishTerminalNodes();
        }
        if (result.cleanupFailed) {
          final cleanupFailure = _retainedCleanupFailure(
            logoutError,
            operation: 'logout',
            message: 'Logout did not cleanly close all native resources.',
          );
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
      if (pendingPersistentPreparation) {
        Object? cleanupError;
        try {
          await _awaitWorkerRecoveryCompletion();
          await _quarantineStateOperation(requestToken);
          await retireNativeAbandonedRuntimeToken(requestToken);
          pendingPersistentPreparation = false;
        } catch (error) {
          cleanupError = error;
        }
        if (cleanupError != null) {
          final cleanupFailure = _retainedCleanupFailure(
            cleanupError,
            operation: 'logout',
            message: 'Idle logout preparation cleanup could not be confirmed.',
          );
          throw TailscaleLogoutException(
            'Logout failed before its prepared state could be safely '
            'released; restart before retrying.',
            code: TailscaleErrorCode.runtimeCleanupFailed,
            cause: cleanupFailure,
          );
        }
      }
      if (shutdownToken case final token?) {
        _shutdownIntents.remove(token);
        _recoveredShutdowns.remove(token);
      }
      _reset();
    }
  }

  /// Irreversibly removes this installation's local Tailscale identity.
  ///
  /// This is deliberately separate from [logout]: it does not contact the
  /// control plane, so the remote node may remain until an administrator or
  /// expiry policy removes it. Native code first stops any active runtime and
  /// durably records reset intent while retaining the state lease. The exact
  /// Keybay DEK is then deleted, followed by only this package's state subtree.
  /// Interrupted resets fail closed and must be resumed by calling this method
  /// again; [up], [status], and [logout] will not guess through the marker.
  @override
  Future<void> forgetLocalIdentity() async {
    _requireInitialized();
    return _supervisorLifecycle.run(_runForgetLocalIdentity);
  }

  Future<void> _runForgetLocalIdentity() async {
    await _awaitWorkerRecovery();
    _reset();

    final token = _allocateRuntimeToken();
    final worker = _workerInstance;
    final activeToken = worker?.runtimeToken;
    late final NativeLocalResetBeginResult begin;
    try {
      begin = await beginNativeLocalReset(token);
    } catch (error) {
      Object? settlementError;
      try {
        // A lost/invalid response can follow a successful native begin. Settle
        // it as unconfirmed so the marker remains but the lease is released.
        await finishNativeLocalReset(token, custodyDeletionSucceeded: false);
      } catch (settlement) {
        settlementError = settlement;
      }
      final cleanupFailed =
          (error is TailscaleOperationException &&
              error.code == TailscaleErrorCode.runtimeCleanupFailed) ||
          (settlementError is TailscaleOperationException &&
              settlementError.code == TailscaleErrorCode.runtimeCleanupFailed);
      if (cleanupFailed) {
        final failure =
            error is TailscaleOperationException &&
                error.code == TailscaleErrorCode.runtimeCleanupFailed
            ? error
            : settlementError! as TailscaleOperationException;
        _retainCleanupFailure(failure);
      }
      throw TailscaleForgetLocalIdentityException(
        cleanupFailed
            ? 'Local reset response recovery did not reach a proven '
                  'quiescent state. Restart before retrying.'
            : 'Local reset could not confirm its durable begin result. Call '
                  'forgetLocalIdentity() again before starting the node.',
        code: cleanupFailed
            ? TailscaleErrorCode.runtimeCleanupFailed
            : TailscaleErrorCode.localResetIncomplete,
        cause: (begin: error, settlement: settlementError),
      );
    }
    if (begin.stopped) {
      if (activeToken != null) worker?.detachRuntimeToken(activeToken);
      _publishTerminalNodes();
      _stateController.add(NodeState.stopped);
    }
    final beginError = begin.error;
    if (beginError != null) {
      if (beginError.code == TailscaleErrorCode.runtimeCleanupFailed) {
        _retainCleanupFailure(beginError);
      }
      throw TailscaleForgetLocalIdentityException(
        'Local identity reset could not establish durable custody.',
        code: beginError.code,
        statusCode: beginError.statusCode,
        cause: beginError,
      );
    }

    TailscaleOperationException? custodyError;
    try {
      await deleteStateStoreDek(_initialization!.keybay);
    } on TailscaleOperationException catch (error) {
      custodyError = error;
    }

    TailscaleOperationException? finishError;
    try {
      await finishNativeLocalReset(
        token,
        custodyDeletionSucceeded: custodyError == null,
      );
    } catch (error) {
      finishError = error is TailscaleOperationException
          ? error
          : TailscaleOperationException(
              'forget local identity',
              'Native local reset did not complete safely.',
              code: TailscaleErrorCode.localResetIncomplete,
              cause: error,
            );
    }

    if (custodyError != null || finishError != null) {
      final cleanupFailed =
          finishError?.code == TailscaleErrorCode.runtimeCleanupFailed;
      if (cleanupFailed) _retainCleanupFailure(finishError!);
      throw TailscaleForgetLocalIdentityException(
        cleanupFailed
            ? 'Secure-storage deletion failed and native cleanup did not '
                  'reach a proven quiescent state. Restart before retrying.'
            : 'Local identity reset is incomplete. Resolve secure-storage '
                  'access and call forgetLocalIdentity() again before '
                  'starting the node.',
        code: cleanupFailed
            ? TailscaleErrorCode.runtimeCleanupFailed
            : TailscaleErrorCode.localResetIncomplete,
        statusCode: finishError?.statusCode,
        cause: (custody: custodyError, native: finishError),
      );
    }

    _idleStatusError = null;
    _publishTerminalNodes();
    _stateController.add(NodeState.noState);
  }

  /// Terminates the supervised control isolate without touching native state —
  /// immediately when [at] is omitted, or armed at that exact lifecycle
  /// injection point (see [DebugTerminatePoint]). The caller-isolate rescue
  /// path must quarantine any matching runtime. [expected] applies only to an
  /// immediate termination.
  @visibleForTesting
  Future<void> debugTerminateWorkerForTesting({
    bool expected = false,
    // Deliberate: this wrapper is itself test-only; the enum's annotation
    // still guards direct production arming.
    // ignore: invalid_use_of_visible_for_testing_member
    DebugTerminatePoint? at,
  }) async {
    _requireInitialized();
    final worker = await _workerForCall();
    await worker.debugWaitUntilReady();
    if (at == null) {
      worker.debugTerminate(expected: expected);
    } else {
      worker.debugArmTermination(at);
    }
  }
}
