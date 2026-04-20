part of 'worker.dart';

/// Entrypoint for the background worker isolate that executes
/// commands against the Tailscale native runtime.
void _workerEntrypoint(SendPort sendPort) {
  ReceivePort? commandPort;
  ReceivePort? watcherPort;
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

    commandPort = ReceivePort();
    watcherPort = ReceivePort();

    native.duneSetDartPort(watcherPort.sendPort.nativePort);

    watcherPort.listen((dynamic message) {
      if (message is! String) return;

      try {
        final parsed = jsonDecode(message) as Map<String, dynamic>;

        if (parsed['type'] == 'error') {
          sendPort.send(
            _WorkerRuntimeErrorEvent(
              TailscaleRuntimeError.fromPushPayload(parsed),
            ),
          );
          return;
        }

        if (parsed['type'] == 'status') {
          final state = NodeState.parse(parsed['state'] as String?);
          sendPort.send(_WorkerStateEvent(state: state));
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
              :stateDir,
            ) = request;

            if (authKey.isEmpty) {
              final stateDirPtr = stateDir.toNativeUtf8();
              try {
                if (native.duneHasState(stateDirPtr) == 0) {
                  throw const TailscaleUpException(
                    'No auth key provided and no existing session state. '
                    'Pass an authKey to authenticate.',
                  );
                }
              } finally {
                calloc.free(stateDirPtr);
              }
            }

            // Allocate inside the try so any partial-allocation failure
            // (hypothetically OOM mid-sequence) still hits the finally and
            // frees what we managed to allocate. The locals start null and
            // the frees guard on nullness.
            ffi.Pointer<Utf8>? hostnamePtr;
            ffi.Pointer<Utf8>? authKeyPtr;
            ffi.Pointer<Utf8>? controlUrlPtr;
            ffi.Pointer<Utf8>? stateDirPtr;

            try {
              hostnamePtr = hostname.toNativeUtf8();
              authKeyPtr = authKey.toNativeUtf8();
              controlUrlPtr = controlUrl.toNativeUtf8();
              stateDirPtr = stateDir.toNativeUtf8();

              native.duneStopWatch();

              final result = _callNativeJson(
                () => native.duneStart(
                  hostnamePtr!,
                  authKeyPtr!,
                  controlUrlPtr!,
                  stateDirPtr!,
                ),
                onError: TailscaleUpException.new,
              ) as Map<String, dynamic>;

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
              if (hostnamePtr != null) calloc.free(hostnamePtr);
              if (authKeyPtr != null) calloc.free(authKeyPtr);
              if (controlUrlPtr != null) calloc.free(controlUrlPtr);
              if (stateDirPtr != null) calloc.free(stateDirPtr);
            }
          case _WorkerListenCommand request:
            final result = _callNativeJson(
              () => native.duneListen(request.localPort, request.tailnetPort),
              onError: TailscaleHttpException.new,
            ) as Map<String, dynamic>;

            final listenPort = result['listenPort'] as int?;
            if (listenPort == null || listenPort <= 0) {
              throw const TailscaleHttpException(
                'Native runtime did not return a usable local listen port.',
              );
            }

            sendPort.send(_WorkerListenResponse(listenPort: listenPort));
          case _WorkerStatusCommand(:final stateDir):
            sendPort.send(_WorkerStatusResponse(
              status: _loadStatusSnapshot(stateDir: stateDir),
            ));
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
              _callNativeJson(
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
            operation: message.operation,
            message: errorMessage,
          ),
        );
      }
    });

    sendPort.send(_WorkerReadyMessage(commandPort.sendPort));
  } catch (error) {
    commandPort?.close();
    watcherPort?.close();
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

/// Calls a native function that returns JSON, decodes it, and checks for an
/// `error` key if the result is a map. Throws via [onError] if an error key is
/// present; otherwise returns the decoded value.
dynamic _callNativeJson(
  ffi.Pointer<Utf8> Function() fn, {
  required TailscaleException Function(String) onError,
}) {
  final result = jsonDecode(_callNativeString(fn));
  if (result is Map<String, dynamic>) {
    final error = result['error'] as String?;
    if (error != null) throw onError(error);
  }
  return result;
}

TailscaleStatus _loadStatusSnapshot({String? stateDir}) {
  try {
    final parsed = _callNativeJson(
      native.duneStatus,
      onError: TailscaleStatusException.new,
    ) as Map<String, dynamic>;

    // When the engine isn't running, duneStatus returns {} which parses
    // to noState. If we have a stateDir to check and persisted credentials
    // exist, report stopped instead so consumers can distinguish "was
    // previously authenticated" from "never authenticated".
    if (parsed.isEmpty && stateDir != null) {
      final stateDirPtr = stateDir.toNativeUtf8();
      try {
        if (native.duneHasState(stateDirPtr) != 0) {
          return TailscaleStatus.stopped;
        }
      } finally {
        calloc.free(stateDirPtr);
      }
    }

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
    final decoded = _callNativeJson(
      native.dunePeers,
      onError: TailscaleStatusException.new,
    );
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
