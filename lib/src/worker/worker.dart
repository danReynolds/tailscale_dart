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
  Worker({required this.publishStatus, required this.publishRuntimeError});

  final void Function(TailscaleStatus status) publishStatus;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;

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

  bool get _isWorkerAlive =>
      _workerIsolate != null ||
      _workerCommandPort != null ||
      _workerPort != null ||
      _workerReadyCompleter != null;

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
      try {
        _workerIsolate = await Isolate.spawn<SendPort>(
          _workerEntrypoint,
          _workerPort!.sendPort,
        );
        _workerIsolate!.addOnExitListener(
          _workerPort!.sendPort,
          response: _workerExitedSentinel,
        );
      } catch (error, stackTrace) {
        _teardownWorker(
          const TailscaleOperationException(
            'worker',
            'Native worker isolate failed to spawn.',
          ),
        );
        Error.throwWithStackTrace(error, stackTrace);
      }

      try {
        await readyCompleter.future;
      } catch (error, stackTrace) {
        _teardownWorker(
          const TailscaleOperationException(
            'worker',
            'Native worker isolate failed to initialize.',
          ),
          killIsolate: true,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      if (identical(_workerReadyCompleter, readyCompleter)) {
        _workerReadyCompleter = null;
      }
    }
  }

  void _handleWorkerMessage(dynamic message) {
    if (message == _workerExitedSentinel) {
      _handleUnexpectedExit();
      return;
    }

    switch (message) {
      case _WorkerReadyMessage(:final commandPort):
        _workerCommandPort = commandPort;
        final ready = _workerReadyCompleter;
        if (ready != null && !ready.isCompleted) ready.complete();
      case _WorkerBootstrapFailureMessage(:final message):
        final ready = _workerReadyCompleter;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(TailscaleOperationException('worker', message));
        } else {
          publishRuntimeError(
            TailscaleRuntimeError(
              message: message,
              code: TailscaleRuntimeErrorCode.node,
            ),
          );
        }
      case _WorkerRuntimeErrorEvent(:final error):
        final running = _runningCompleter;
        if (running != null && !running.isCompleted) {
          running.completeError(TailscaleUpException(error.message));
        }
        publishRuntimeError(error);
      case _WorkerStatusEvent(:final snapshot):
        if (snapshot.nodeStatus == NodeStatus.running) {
          final running = _runningCompleter;
          if (running != null && !running.isCompleted) running.complete();
        }
        publishStatus(snapshot);
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

  void _handleUnexpectedExit() {
    const error = TailscaleOperationException(
      'worker',
      'Native worker isolate terminated unexpectedly.',
    );
    // The worker is already gone, so this is the one teardown path that must
    // attempt native cleanup itself before resetting worker state.
    _stopNativeRuntimeAfterUnexpectedExit();
    final running = _runningCompleter;
    if (running != null && !running.isCompleted) {
      running.completeError(TailscaleUpException(error.message));
    }
    _teardownWorker(error);
  }

  void _teardownWorker(Object error, {bool killIsolate = false}) {
    final ready = _workerReadyCompleter;
    if (ready != null && !ready.isCompleted) ready.completeError(error);

    final running = _runningCompleter;
    if (running != null && !running.isCompleted) running.completeError(error);

    for (final completer in _pendingWorkerResponses) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pendingWorkerResponses.clear();

    final isolate = _workerIsolate;
    _runningCompleter = null;
    _workerIsolate = null;
    _workerCommandPort = null;
    _workerReadyCompleter = null;
    _workerPort?.close();
    _workerPort = null;

    if (killIsolate) isolate?.kill(priority: Isolate.immediate);
  }

  void shutdown() {
    if (!_isWorkerAlive) return;

    _clearNativePort();
    _teardownWorker(
      const TailscaleOperationException(
        'worker',
        'Native worker isolate shut down.',
      ),
      killIsolate: true,
    );
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

  bool debugEventDoesNotConsumePendingResponse() {
    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    try {
      _handleWorkerMessage(
        const _WorkerStatusEvent(snapshot: TailscaleStatus.stopped),
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

    _handleUnexpectedExit();

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

void _clearNativePort() {
  native.duneSetDartPort(0);
}

void _stopNativeRuntimeAfterUnexpectedExit() {
  native.duneStopWatch();
  _clearNativePort();
  native.duneStop();
}
