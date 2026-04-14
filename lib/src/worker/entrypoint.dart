part of 'worker.dart';

/// Entrypoint for the background worker isolate that executes
/// commands against the Tailscale native runtime.
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
            final _WorkerStartCommand(
              :authKey,
              :controlUrl,
              :hostname,
              :stateDir
            ) = request;

            final hostnamePtr = hostname.toNativeUtf8();
            final authKeyPtr = authKey.toNativeUtf8();
            final controlUrlPtr = controlUrl.toNativeUtf8();
            final stateDirPtr = stateDir.toNativeUtf8();

            try {
              native.duneStopWatch();

              final result = _callNativeMap(
                () => native.duneStart(
                    hostnamePtr, authKeyPtr, controlUrlPtr, stateDirPtr),
                onError: TailscaleUpException.new,
              );

              final proxyPort = result['proxyPort'] as int? ?? 0;
              final proxyAuthToken = result['proxyAuthToken'] as String?;
              if (proxyPort == 0 ||
                  proxyAuthToken == null ||
                  proxyAuthToken.isEmpty) {
                throw const TailscaleUpException(
                  'Failed to start Tailscale: native runtime did not return a usable proxy endpoint.',
                );
              }

              native.duneStartWatch();

              sendPort.send(
                _WorkerStartResponse(
                  proxyPort: proxyPort,
                  proxyAuthToken: proxyAuthToken,
                ),
              );
            } finally {
              calloc.free(hostnamePtr);
              calloc.free(authKeyPtr);
              calloc.free(controlUrlPtr);
              calloc.free(stateDirPtr);
            }
          case _WorkerListenCommand request:
            final result = _callNativeMap(
              () => native.duneListen(request.localPort, request.tailnetPort),
              onError: TailscaleListenException.new,
            );

            final listenPort = result['listenPort'] as int?;
            if (listenPort == null || listenPort <= 0) {
              throw const TailscaleListenException(
                'Native runtime did not return a usable local listen port.',
              );
            }

            sendPort.send(
              _WorkerListenResponse(
                listenPort: listenPort,
              ),
            );
          case _WorkerStatusCommand():
            sendPort.send(_WorkerStatusResponse(status: _loadStatusSnapshot()));
          case _WorkerPeersCommand():
            sendPort.send(_WorkerPeersResponse(peers: _loadPeerSnapshot()));
          case _WorkerDownCommand():
            native.duneStopWatch();
            native.duneStop();

            sendPort.send(const _WorkerAckResponse(_WorkerOperation.down));
          case _WorkerLogoutCommand request:
            native.duneStopWatch();

            final stateDirPtr = request.stateDir.toNativeUtf8();
            try {
              _callNativeMap(
                () => native.duneLogout(stateDirPtr),
                onError: TailscaleLogoutException.new,
              );
            } finally {
              calloc.free(stateDirPtr);
            }

            sendPort.send(const _WorkerAckResponse(_WorkerOperation.logout));
        }
      } catch (error) {
        final errorMessage = switch (error) {
          TailscaleException _ => error.message,
          _ => error.toString(),
        };

        return sendPort.send(
          _WorkerFailureResponse(
              operation: message.operation, message: errorMessage),
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

// ---------------------------------------------------------------------------
// FFI helpers — called exclusively on the worker isolate.
// ---------------------------------------------------------------------------

String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

/// Calls a native function that returns a JSON map, decodes it, and checks for
/// an `error` key. Throws via [onError] if present; otherwise returns the map.
Map<String, dynamic> _callNativeMap(
  ffi.Pointer<Utf8> Function() fn, {
  required TailscaleException Function(String) onError,
}) {
  final result = Map<String, dynamic>.from(
    jsonDecode(_callNativeString(fn)) as Map<String, dynamic>,
  );
  final error = result['error'] as String?;
  if (error != null) throw onError(error);
  return result;
}

TailscaleStatus _loadStatusSnapshot() {
  try {
    final parsed = _callNativeMap(
      native.duneStatus,
      onError: TailscaleStatusException.new,
    );
    return TailscaleStatus.fromJson(parsed);
  } catch (error) {
    if (error is TailscaleStatusException) rethrow;
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
    if (error is TailscaleStatusException) rethrow;
    throw TailscaleStatusException(
      'Failed to decode native Tailscale peers.',
      cause: error,
    );
  }
}
