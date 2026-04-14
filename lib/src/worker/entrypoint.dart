part of 'worker.dart';

/// The entrypoint to the background worker isolate. Handles commands from the native isolate
/// and executes them against the Tailscale native runtime.
void _workerEntrypoint(SendPort sendPort) {
  try {
    final initResult = native.duneInitDartAPI(
      ffi.NativeApi.initializeApiDLData,
    );
    if (initResult != 0) {
      sendPort.send(
        const _WorkerBootstrapFailureMessage(
          'Failed to initialize the Dart native API bridge.',
        ),
      );
      return;
    }

    final commandPort = ReceivePort();
    final watcherPort = ReceivePort();
    native.duneSetDartPort(watcherPort.sendPort.nativePort);

    // Watcher port used to receive messages from the native runtime including status updates and errors.
    watcherPort.listen((dynamic message) {
      if (message is! String) return;

      try {
        final parsed = jsonDecode(message) as Map<String, dynamic>;

        if (parsed['type'] == 'error') {
          sendPort.send(
            _WorkerRuntimeErrorEvent(
                TailscaleRuntimeError.fromPushPayload(parsed)),
          );
          return;
        }

        if (parsed['type'] == 'status') {
          final state = parsed['state'] as String?;
          TailscaleStatus? snapshot;

          try {
            snapshot = _loadStatusSnapshot();
          } on TailscaleStatusException catch (error) {
            sendPort.send(
              _WorkerRuntimeErrorEvent(
                TailscaleRuntimeError(
                  message: error.message,
                  code: TailscaleRuntimeErrorCode.node,
                ),
              ),
            );
          }

          sendPort.send(_WorkerStatusEvent(state: state, snapshot: snapshot));
        }
      } catch (_) {
        // Malformed message from Go — ignore.
      }
    });

    commandPort.listen((dynamic message) {
      if (message is! _WorkerCommand) return;

      try {
        switch (message) {
          case _WorkerStartCommand request:
            native.duneStopWatch();
            final result = _startNativeRuntime(
              hostname: request.hostname,
              authKey: request.authKey,
              controlUrl: request.controlUrl,
              stateDir: request.stateDir,
            );
            native.duneStartWatch();
            sendPort.send(
              _WorkerStartResponse(
                proxyPort: result.proxyPort,
                proxyAuthToken: result.proxyAuthToken,
              ),
            );
          case _WorkerListenCommand request:
            sendPort.send(
              _WorkerListenResponse(
                listenPort: _listenNativeRuntime(
                  localPort: request.localPort,
                  tailnetPort: request.tailnetPort,
                ),
              ),
            );
          case _WorkerStatusCommand():
            sendPort.send(_WorkerStatusResponse(status: _loadStatusSnapshot()));
          case _WorkerPeersCommand():
            sendPort.send(_WorkerPeersResponse(peers: _loadPeerSnapshot()));
          case _WorkerDownCommand():
            _downNativeRuntime();
            sendPort.send(const _WorkerAckResponse(_WorkerOperation.down));
          case _WorkerLogoutCommand request:
            _logoutNativeRuntime(request.stateDir);
            sendPort.send(const _WorkerAckResponse(_WorkerOperation.logout));
        }
      } catch (error) {
        sendPort.send(
          _workerFailureForError(operation: message.operation, error: error),
        );
      }
    });

    sendPort.send(_WorkerReadyMessage(commandPort.sendPort));
  } catch (error) {
    sendPort.send(
      _WorkerBootstrapFailureMessage(
        'Native worker isolate failed to start: $error',
      ),
    );
  }
}
