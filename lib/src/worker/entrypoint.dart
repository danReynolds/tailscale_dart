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

    commandPort.listen((dynamic message) async {
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

            final hostnamePtr = hostname.toNativeUtf8();
            final authKeyPtr = authKey.toNativeUtf8();
            final controlUrlPtr = controlUrl.toNativeUtf8();
            final stateDirPtr = stateDir.toNativeUtf8();

            try {
              native.duneStopWatch();

              final result = _callNativeJson(
                () => native.duneStart(
                  hostnamePtr,
                  authKeyPtr,
                  controlUrlPtr,
                  stateDirPtr,
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
              calloc.free(hostnamePtr);
              calloc.free(authKeyPtr);
              calloc.free(controlUrlPtr);
              calloc.free(stateDirPtr);
            }
          case _WorkerListenCommand request:
            final result = _callNativeJson(
              () => native.duneListen(request.localPort, request.tailnetPort),
              onError: TailscaleListenException.new,
            ) as Map<String, dynamic>;

            final listenPort = result['listenPort'] as int?;
            if (listenPort == null || listenPort <= 0) {
              throw const TailscaleListenException(
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

            // Go's Stop() calls publishState("Stopped") synchronously, which
            // posts on [watcherPort]. That port is a worker-local ReceivePort
            // whose listener forwards to main as a _WorkerStateEvent — but
            // the listener only fires on the next event-loop iteration. If
            // we ack now, main sees [ack, state] and `await tsnet.down()`
            // resolves BEFORE subscribers see Stopped, leaving a race for
            // any code that subscribes after the await. Yield here so the
            // watcherPort drains first, then send the ack — after this the
            // API contract is "await down() implies Stopped has been
            // delivered to onStateChange".
            await _drainWatcherPort();
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

            // Logout's Stop() publishes Stopped (if wasRunning) and then
            // publishState("NoState") fires — queuing up to two events on
            // watcherPort. Drain both before ack'ing so subscribers see the
            // full sequence before `await logout()` resolves.
            await _drainWatcherPort();
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

// Yields to the worker's event loop so any messages already queued on
// watcherPort (from synchronous calls to Go's publishState inside duneStop /
// duneLogout) are drained — i.e., their listener runs and forwards a
// _WorkerStateEvent to main — before the caller's next `sendPort.send`.
//
// A single zero-duration Timer yields past all earlier-queued external
// events: Dart's event loop processes events FIFO, so port messages posted
// during the preceding sync native call fire before the timer does, and
// this await resumes only after they've all been drained. This is what
// lets the public API promise "await down()/logout() implies the state
// event has been delivered to onStateChange subscribers."
Future<void> _drainWatcherPort() => Future<void>.delayed(Duration.zero);

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
