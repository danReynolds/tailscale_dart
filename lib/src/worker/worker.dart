part of tailscale_dart;

String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

TailscaleStatus _loadStatusSnapshot() {
  try {
    final parsed = Map<String, dynamic>.from(
      jsonDecode(_callNativeString(native.duneStatus)) as Map<String, dynamic>,
    );
    final error = parsed['error'] as String?;
    if (error != null) {
      throw TailscaleStatusException(error);
    }
    return TailscaleStatus.fromJson(parsed);
  } catch (error) {
    if (error is TailscaleStatusException) {
      rethrow;
    }
    throw TailscaleStatusException(
      'Failed to decode native Tailscale status.',
      cause: error,
    );
  }
}

List<PeerStatus> _loadPeerSnapshot() {
  try {
    final decoded = jsonDecode(_callNativeString(native.dunePeers));
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'] as String?;
      if (error != null) {
        throw TailscaleStatusException(error);
      }
    }

    if (decoded is! List<dynamic>) {
      throw const TailscaleStatusException(
        'Failed to decode native Tailscale peers.',
      );
    }

    return PeerStatus.listFromJson(decoded);
  } catch (error) {
    if (error is TailscaleStatusException) {
      rethrow;
    }
    throw TailscaleStatusException(
      'Failed to decode native Tailscale peers.',
      cause: error,
    );
  }
}

final class _NativeStartResult {
  const _NativeStartResult({
    required this.proxyPort,
    required this.proxyAuthToken,
  });

  final int proxyPort;
  final String proxyAuthToken;
}

Map<String, dynamic> _decodeNativeMapResult(String json) {
  return Map<String, dynamic>.from(jsonDecode(json) as Map<String, dynamic>);
}

_NativeStartResult _startNativeRuntime({
  required String hostname,
  required String authKey,
  required String controlUrl,
  required String stateDir,
}) {
  final p1 = hostname.toNativeUtf8();
  final p2 = authKey.toNativeUtf8();
  final p3 = controlUrl.toNativeUtf8();
  final p4 = stateDir.toNativeUtf8();

  try {
    final result = _decodeNativeMapResult(
      _callNativeString(() {
        return native.duneStart(p1, p2, p3, p4);
      }),
    );

    final error = result['error'] as String?;
    if (error != null) {
      throw TailscaleUpException(error);
    }

    final proxyPort = result['proxyPort'] as int? ?? 0;
    final proxyAuthToken = result['proxyAuthToken'] as String?;
    if (proxyPort == 0 || proxyAuthToken == null || proxyAuthToken.isEmpty) {
      throw const TailscaleUpException(
        'Failed to start Tailscale: native runtime did not return a usable proxy endpoint.',
      );
    }

    return _NativeStartResult(
      proxyPort: proxyPort,
      proxyAuthToken: proxyAuthToken,
    );
  } finally {
    calloc.free(p1);
    calloc.free(p2);
    calloc.free(p3);
    calloc.free(p4);
  }
}

int _listenNativeRuntime({required int localPort, required int tailnetPort}) {
  final result = _decodeNativeMapResult(
    _callNativeString(() {
      return native.duneListen(localPort, tailnetPort);
    }),
  );

  final error = result['error'] as String?;
  if (error != null) {
    throw TailscaleListenException(error);
  }

  final listenPort = result['listenPort'] as int?;
  if (listenPort == null || listenPort <= 0) {
    throw const TailscaleListenException(
      'Native runtime did not return a usable local listen port.',
    );
  }

  return listenPort;
}

void _downNativeRuntime() {
  native.duneStopWatch();
  native.duneStop();
}

void _logoutNativeRuntime(String stateDir) {
  native.duneStopWatch();

  final dirPtr = stateDir.toNativeUtf8();
  try {
    final result = _decodeNativeMapResult(
      _callNativeString(() {
        return native.duneLogout(dirPtr);
      }),
    );
    final error = result['error'] as String?;
    if (error != null) {
      throw TailscaleLogoutException(error);
    }
  } finally {
    calloc.free(dirPtr);
  }
}

void _handleWorkerWatcherMessage(dynamic message, SendPort mainInboxPort) {
  if (message is! String) return;

  try {
    final parsed = jsonDecode(message) as Map<String, dynamic>;

    if (parsed['type'] == 'error') {
      mainInboxPort.send(
        _WorkerRuntimeErrorEvent(TailscaleRuntimeError.fromPushPayload(parsed)),
      );
      return;
    }

    if (parsed['type'] == 'status') {
      final state = parsed['state'] as String?;
      TailscaleStatus? snapshot;

      try {
        snapshot = _loadStatusSnapshot();
      } on TailscaleStatusException catch (error) {
        mainInboxPort.send(
          _WorkerRuntimeErrorEvent(
            TailscaleRuntimeError(
              message: error.message,
              code: TailscaleRuntimeErrorCode.node,
            ),
          ),
        );
      }

      mainInboxPort.send(_WorkerStatusEvent(state: state, snapshot: snapshot));
    }
  } catch (_) {
    // Malformed message from Go — ignore.
  }
}

void _handleWorkerCommand(_WorkerCommand message, SendPort sendPort) {
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
}

void _nativeWorkerMain(SendPort sendPort) {
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

    watcherPort.listen((dynamic message) {
      _handleWorkerWatcherMessage(message, sendPort);
    });

    commandPort.listen((dynamic message) {
      if (message is! _WorkerCommand) return;
      _handleWorkerCommand(message, sendPort);
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
