library tailscale_dart.worker;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../errors.dart';
import '../ffi_bindings.dart' as native;
import '../status.dart';

part 'messages.dart';
part 'entrypoint.dart';

const _workerExitedSentinel = '_tailscaleWorkerExited';

/// The main isolate worker used by [Tailscale] to perform native Tailscale operations.
final class Worker {
  Worker({
    required this.publishStatus,
    required this.publishRuntimeError,
    required this.publishCurrentStatus,
  });

  final void Function(TailscaleStatus status) publishStatus;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;
  final Future<TailscaleStatus> Function() publishCurrentStatus;

  // Commands are processed synchronously on the worker isolate and each
  // command produces exactly one response in request order, so a FIFO queue is
  // sufficient for matching RPC responses without request IDs.
  final Queue<Completer<_WorkerResponse>> _pendingWorkerResponses =
      Queue<Completer<_WorkerResponse>>();

  ReceivePort? _workerPort;
  Isolate? _workerIsolate;
  SendPort? _workerCommandPort;
  Completer<void>? _workerReadyCompleter;

  Completer<void>? _runningCompleter;

  Future<void> _ensureWorkerStarted() async {
    if (_workerCommandPort != null) return;
    if (_workerReadyCompleter != null) {
      return _workerReadyCompleter!.future;
    }

    final readyCompleter = Completer<void>();
    _workerReadyCompleter = readyCompleter;

    _workerPort = ReceivePort();
    _workerPort!.listen(_handleWorkerMessage);

    try {
      _workerIsolate = await Isolate.spawn<SendPort>(
        _workerEntrypoint,
        _workerPort!.sendPort,
      );
      _workerIsolate!.addOnExitListener(
        _workerPort!.sendPort,
        response: _workerExitedSentinel,
      );
      await readyCompleter.future;
    } catch (error, stackTrace) {
      _reset();
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (identical(_workerReadyCompleter, readyCompleter)) {
        _workerReadyCompleter = null;
      }
    }
  }

  void _handleWorkerMessage(dynamic message) {
    if (message == _workerExitedSentinel) {
      _exit();
      return;
    }

    switch (message) {
      case _WorkerReadyMessage(:final commandPort):
        _workerCommandPort = commandPort;
        _tryComplete(_workerReadyCompleter);
      case _WorkerBootstrapFailureMessage(:final message):
        final ready = _workerReadyCompleter;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(TailscaleUpException(message));
        } else {
          publishRuntimeError(
            TailscaleRuntimeError(
              message: message,
              code: TailscaleRuntimeErrorCode.node,
            ),
          );
        }
      case _WorkerRuntimeErrorEvent(:final error):
        _failRunningWaiter(TailscaleUpException(error.message));
        publishRuntimeError(error);
      case _WorkerStatusEvent(:final state, :final snapshot):
        if (state == 'Running') _resolveRunningWaiter();
        snapshot != null
            ? publishStatus(snapshot)
            : unawaited(publishCurrentStatus());
      case _WorkerResponse():
        if (_pendingWorkerResponses.isEmpty) {
          publishRuntimeError(
            const TailscaleRuntimeError(
              message: 'Native worker isolate returned an unexpected response.',
              code: TailscaleRuntimeErrorCode.node,
            ),
          );
          return;
        }

        final completer = _pendingWorkerResponses.removeFirst();
        if (!completer.isCompleted) {
          completer.complete(message);
        }
      default:
        // Ignore unknown messages.
        break;
    }
  }

  void _exit() {
    const error = TailscaleOperationException(
      'worker',
      'Native worker isolate terminated unexpectedly.',
    );
    _failRunningWaiter(TailscaleUpException(error.message));
    _teardown(error);
  }

  void _reset() {
    const error = TailscaleOperationException(
      'worker',
      'Native worker isolate failed to initialize.',
    );
    _workerIsolate?.kill(priority: Isolate.immediate);
    _teardown(error);
  }

  void _teardown(Object error) {
    _tryCompleteError(_workerReadyCompleter, error);

    final pending = _pendingWorkerResponses.toList(growable: false);
    _pendingWorkerResponses.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    _workerIsolate = null;
    _workerCommandPort = null;
    _workerReadyCompleter = null;
    _workerPort?.close();
    _workerPort = null;
  }

  Future<TResponse> _request<TResponse extends _WorkerResponse>(
    _WorkerCommand request,
  ) async {
    await _ensureWorkerStarted();

    final commandPort = _workerCommandPort;
    if (commandPort == null) {
      throw const TailscaleOperationException(
        'worker',
        'Native worker isolate is not ready.',
      );
    }

    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    try {
      commandPort.send(request);
      final response = await completer.future;
      if (response is _WorkerFailureResponse) {
        throw response.operation.exceptionForMessage(response.message);
      }

      return response as TResponse;
    } catch (error) {
      _pendingWorkerResponses.remove(completer);
      rethrow;
    }
  }

  Future<NativeWorkerStartResult> start({
    required String hostname,
    required String authKey,
    required String controlUrl,
    required String stateDir,
  }) async {
    final response = await _request<_WorkerStartResponse>(
      _WorkerStartCommand(
        hostname: hostname,
        authKey: authKey,
        controlUrl: controlUrl,
        stateDir: stateDir,
      ),
    );
    return response.toResult();
  }

  Future<int> listen({required int localPort, required int tailnetPort}) async {
    final response = await _request<_WorkerListenResponse>(
      _WorkerListenCommand(localPort: localPort, tailnetPort: tailnetPort),
    );
    return response.listenPort;
  }

  Future<TailscaleStatus> status() async {
    final response = await _request<_WorkerStatusResponse>(
      const _WorkerStatusCommand(),
    );
    return response.status;
  }

  Future<List<PeerStatus>> peers() async {
    final response = await _request<_WorkerPeersResponse>(
      const _WorkerPeersCommand(),
    );
    return response.peers;
  }

  Future<void> down() async {
    await _request<_WorkerAckResponse>(const _WorkerDownCommand());
  }

  Future<void> logout(String stateDir) async {
    await _request<_WorkerAckResponse>(
      _WorkerLogoutCommand(stateDir: stateDir),
    );
  }

  Future<void> waitForRunning(
    Duration timeout, {
    required TailscaleTimeoutException Function() onTimeout,
  }) async {
    _runningCompleter = Completer<void>();

    try {
      await _runningCompleter!.future.timeout(
        timeout,
        onTimeout: () => throw onTimeout(),
      );
    } finally {
      _runningCompleter = null;
    }
  }

  void _failRunningWaiter(TailscaleUpException error) {
    _tryCompleteError(_runningCompleter, error);
  }

  void _resolveRunningWaiter() {
    _tryComplete(_runningCompleter);
  }

  static void _tryComplete(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  static void _tryCompleteError(Completer<void>? completer, Object error) {
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  bool debugEventDoesNotConsumePendingResponse() {
    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    try {
      _handleWorkerMessage(
        const _WorkerStatusEvent(
          state: 'Starting',
          snapshot: TailscaleStatus.stopped,
        ),
      );

      if (_pendingWorkerResponses.length != 1 || completer.isCompleted) {
        return false;
      }

      _handleWorkerMessage(const _WorkerAckResponse(_WorkerOperation.down));
      return _pendingWorkerResponses.isEmpty && completer.isCompleted;
    } finally {
      _pendingWorkerResponses.clear();
    }
  }

  Future<bool> debugExitFailsPendingResponse() async {
    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    _exit();

    try {
      await completer.future;
      return false;
    } catch (error) {
      return error is TailscaleOperationException &&
          error.operation == 'worker';
    } finally {
      _pendingWorkerResponses.clear();
    }
  }
}

final class NativeWorkerStartResult {
  const NativeWorkerStartResult({
    required this.proxyPort,
    required this.proxyAuthToken,
  });

  final int proxyPort;
  final String proxyAuthToken;
}
