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
        final runtimeToken = parsed['runtimeToken'] as int? ?? 0;

        if (parsed['type'] == 'runtimeTerminated') {
          sendPort.send(
            _WorkerRuntimeTerminatedEvent(
              runtimeToken: runtimeToken,
              message:
                  parsed['error'] as String? ?? 'Native runtime terminated.',
              code: parseTailscaleErrorCode(parsed['code'] as String?),
              emitStopped: parsed['emitStopped'] == true,
              cleanupFailed: parsed['cleanupFailed'] == true,
              reportRuntimeError: parsed['reportRuntimeError'] == true,
            ),
          );
          return;
        }

        if (parsed['type'] == 'error') {
          sendPort.send(
            _WorkerRuntimeErrorEvent(
              runtimeToken: runtimeToken,
              error: TailscaleRuntimeError.fromPushPayload(parsed),
            ),
          );
          return;
        }

        if (parsed['type'] == 'status') {
          final state = NodeState.parse(parsed['state'] as String?);
          sendPort.send(
            _WorkerStateEvent(runtimeToken: runtimeToken, state: state),
          );
          return;
        }

        if (parsed['type'] == 'peers') {
          final raw = parsed['peers'] as List<dynamic>? ?? const [];
          sendPort.send(
            _WorkerPeersEvent(
              runtimeToken: runtimeToken,
              peers: TailscaleNode.listFromJson(raw),
            ),
          );
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
              :requestToken,
              :authKey,
              :controlUrl,
              :ephemeral,
              :hostname,
              :hostNetworkSnapshot,
              :bootstrapBudgetMillis,
            ) = request;

            // Allocate inside the try so any partial-allocation failure
            // (hypothetically OOM mid-sequence) still hits the finally and
            // frees what we managed to allocate. The locals start null and
            // the frees guard on nullness.
            ffi.Pointer<Utf8>? hostnamePtr;
            ffi.Pointer<Utf8>? authKeyPtr;
            ffi.Pointer<Utf8>? controlUrlPtr;
            ffi.Pointer<Utf8>? hostNetworkSnapshotPtr;

            try {
              hostnamePtr = hostname.toNativeUtf8();
              authKeyPtr = authKey.toNativeUtf8();
              controlUrlPtr = controlUrl.toNativeUtf8();
              hostNetworkSnapshotPtr = hostNetworkSnapshot.toNativeUtf8();

              final result =
                  _callNativeJson(
                        () => native.duneStart(
                          requestToken,
                          hostnamePtr!,
                          authKeyPtr!,
                          controlUrlPtr!,
                          ephemeral ? 1 : 0,
                          hostNetworkSnapshotPtr!,
                          bootstrapBudgetMillis,
                        ),
                        onError: TailscaleUpException.new,
                      )
                      as Map<String, dynamic>;

              final alreadyActive = result['alreadyActive'] == true;
              final runtimeToken = result['runtimeToken'] as int? ?? 0;
              if (runtimeToken <= 0) {
                throw const TailscaleUpException(
                  'Native runtime did not return its preparation token.',
                );
              }
              if (!alreadyActive) {
                native.duneStartWatch();
              }

              sendPort.send(
                _WorkerStartResponse(
                  alreadyActive: alreadyActive,
                  runtimeToken: runtimeToken,
                ),
              );
            } finally {
              if (hostnamePtr != null) calloc.free(hostnamePtr);
              if (authKeyPtr != null) {
                final bytes = authKeyPtr.cast<ffi.Uint8>().asTypedList(
                  authKeyPtr.length + 1,
                );
                bytes.fillRange(0, bytes.length, 0);
                calloc.free(authKeyPtr);
              }
              if (controlUrlPtr != null) calloc.free(controlUrlPtr);
              if (hostNetworkSnapshotPtr != null) {
                calloc.free(hostNetworkSnapshotPtr);
              }
            }
          case _WorkerHttpCloseBindingCommand request:
            native.duneHttpCloseBinding(request.bindingId);
            sendPort.send(
              const _WorkerAckResponse(_WorkerOperation.httpCloseBinding),
            );
          case _WorkerTcpCloseFdListenerCommand request:
            native.duneTcpCloseFdListener(request.listenerId);
            sendPort.send(
              const _WorkerAckResponse(_WorkerOperation.tcpCloseFdListener),
            );
          case _WorkerUdpCloseBindingCommand request:
            native.duneUdpCloseBinding(request.bindingId);
            sendPort.send(
              const _WorkerAckResponse(_WorkerOperation.udpCloseBinding),
            );
          case _WorkerWhoIsCommand request:
            final ipPtr = request.ip.toNativeUtf8();
            try {
              final result =
                  _callNativeJson(
                        () => native.duneWhoIs(ipPtr),
                        onError: TailscaleStatusException.new,
                      )
                      as Map<String, dynamic>;
              sendPort.send(
                _WorkerWhoIsResponse(identity: _parseWhoIsResponse(result)),
              );
            } finally {
              calloc.free(ipPtr);
            }
          case _WorkerTlsDomainsCommand():
            final result =
                _callNativeJson(
                      native.duneTlsDomains,
                      onError: TailscaleTlsException.new,
                    )
                    as Map<String, dynamic>;
            final domains =
                (result['domains'] as List?)?.whereType<String>().toList(
                  growable: false,
                ) ??
                const [];
            sendPort.send(_WorkerTlsDomainsResponse(domains: domains));
          case _WorkerDiagMetricsCommand():
            final result =
                _callNativeJson(
                      native.duneDiagMetrics,
                      onError: TailscaleDiagException.new,
                    )
                    as Map<String, dynamic>;
            sendPort.send(
              _WorkerDiagMetricsResponse(
                metrics: result['metrics'] as String? ?? '',
              ),
            );
          case _WorkerDiagDERPMapCommand():
            final result =
                _callNativeJson(
                      native.duneDiagDERPMap,
                      onError: TailscaleDiagException.new,
                    )
                    as Map<String, dynamic>;
            sendPort.send(
              _WorkerDiagDERPMapResponse(map: _parseDERPMap(result)),
            );
          case _WorkerDebugNodeStateCommand():
            final result =
                _callNativeJson(
                      native.duneDebugNodeState,
                      onError: TailscaleDiagException.new,
                    )
                    as Map<String, dynamic>;
            sendPort.send(
              _WorkerDebugNodeStateResponse(
                snapshot: NodeStateSnapshot(
                  epoch: result['epoch'] as int? ?? 0,
                  servePublications: result['servePublications'] as int? ?? 0,
                  httpBindings: result['httpBindings'] as int? ?? 0,
                  tcpListeners: result['tcpListeners'] as int? ?? 0,
                  udpBridges: result['udpBridges'] as int? ?? 0,
                  transportCached: result['transportCached'] as bool? ?? false,
                ),
              ),
            );
          case _WorkerDiagCheckUpdateCommand():
            final result =
                _callNativeJson(
                      native.duneDiagCheckUpdate,
                      onError: TailscaleDiagException.new,
                    )
                    as Map<String, dynamic>;
            sendPort.send(
              _WorkerDiagCheckUpdateResponse(
                clientVersion: _parseClientVersion(result),
              ),
            );
          case _WorkerStatusCommand():
            sendPort.send(_WorkerStatusResponse(status: _loadStatusSnapshot()));
          case _WorkerPeersCommand():
            sendPort.send(_WorkerPeersResponse(peers: _loadPeerSnapshot()));
          case _WorkerPrefsGetCommand():
            final result =
                _callNativeJson(
                      native.dunePrefsGet,
                      onError: TailscalePrefsException.new,
                    )
                    as Map<String, dynamic>;
            sendPort.send(
              _WorkerPrefsResponse(
                operation: _WorkerOperation.prefsGet,
                prefs: _parsePrefs(result),
              ),
            );
          case _WorkerPrefsUpdateCommand request:
            final updatePtr = request.updateJson.toNativeUtf8();
            try {
              final result =
                  _callNativeJson(
                        () => native.dunePrefsUpdate(updatePtr),
                        onError: TailscalePrefsException.new,
                      )
                      as Map<String, dynamic>;
              sendPort.send(
                _WorkerPrefsResponse(
                  operation: _WorkerOperation.prefsUpdate,
                  prefs: _parsePrefs(result),
                ),
              );
            } finally {
              calloc.free(updatePtr);
            }
          case _WorkerExitNodeSuggestCommand():
            final result =
                _callNativeJson(
                      native.duneExitNodeSuggest,
                      onError: TailscaleExitNodeException.new,
                    )
                    as Map<String, dynamic>;
            final nodeId = result['nodeId'] as String?;
            sendPort.send(
              _WorkerExitNodeSuggestResponse(
                nodeId: nodeId == null || nodeId.isEmpty ? null : nodeId,
              ),
            );
          case _WorkerExitNodeUseAutoCommand():
            _callNativeJson(
              native.duneExitNodeUseAuto,
              onError: TailscaleExitNodeException.new,
            );
            sendPort.send(
              const _WorkerAckResponse(_WorkerOperation.exitNodeUseAuto),
            );
          case _WorkerServeClearCommand request:
            final payloadPtr = request.payloadJson.toNativeUtf8();
            try {
              _callNativeJson(
                () => native.duneServeClear(payloadPtr),
                onError: _publicationException(
                  request.operation == _WorkerOperation.funnelClear,
                ),
              );
              sendPort.send(_WorkerAckResponse(request.operation));
            } finally {
              calloc.free(payloadPtr);
            }
          case _WorkerDownCommand(
            :final runtimeToken,
            :final terminateAfterNativeResult,
          ):
            final result =
                _decodeNativeJson(() => native.duneStop(runtimeToken))
                    as Map<String, dynamic>;
            if (terminateAfterNativeResult) Isolate.exit();
            sendPort.send(
              _WorkerAckResponse(
                _WorkerOperation.down,
                runtimeToken: result['token'] as int? ?? runtimeToken,
                matched: result['matched'] == true,
                started: result['started'] == true,
                emitStopped: result['emitStopped'] == true,
                cleanupFailed: result['cleanupFailed'] == true,
                errorMessage: result['error'] as String?,
                errorCode: parseTailscaleErrorCode(result['code'] as String?),
                statusCode: result['statusCode'] as int?,
              ),
            );
          case _WorkerLogoutCommand request:
            final snapshotPtr = request.hostNetworkSnapshot.toNativeUtf8();
            late final Map<String, dynamic> result;
            try {
              result =
                  _decodeNativeJson(
                        () => native.duneLogout(
                          request.runtimeToken,
                          snapshotPtr,
                        ),
                      )
                      as Map<String, dynamic>;
            } finally {
              calloc.free(snapshotPtr);
            }
            if (request.terminateAfterNativeResult) Isolate.exit();
            sendPort.send(
              _WorkerAckResponse(
                _WorkerOperation.logout,
                runtimeToken: result['token'] as int? ?? request.runtimeToken,
                started: result['started'] == true,
                emitStopped: result['emitStopped'] == true,
                noState: result['noState'] == true,
                cleanupFailed: result['cleanupFailed'] == true,
                errorMessage: result['error'] as String?,
                errorCode: parseTailscaleErrorCode(result['code'] as String?),
                statusCode: result['statusCode'] as int?,
              ),
            );
        }
      } catch (error) {
        final errorMessage = error is TailscaleException
            ? error.message
            : error.toString();
        final (:code, :statusCode) = switch (error) {
          TailscaleOperationException(:final code, :final statusCode) => (
            code: code,
            statusCode: statusCode,
          ),
          _ => (code: TailscaleErrorCode.unknown, statusCode: null),
        };

        return sendPort.send(
          _WorkerFailureResponse(
            operation: message.operation,
            message: errorMessage,
            code: code,
            statusCode: statusCode,
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
// FFI helpers — thin delegates to the shared native envelope decoder in
// `native_error_code.dart`, kept so worker call sites stay short.
// ---------------------------------------------------------------------------

/// Calls a native function that returns JSON, decodes it, and checks for an
/// `error` key if the result is a map. Throws via [onError] if an error key is
/// present; otherwise returns the decoded value.
dynamic _callNativeJson(
  ffi.Pointer<Utf8> Function() fn, {
  required NativeEnvelopeErrorFactory onError,
}) => decodeNativeEnvelope(fn, onError: onError);

dynamic _decodeNativeJson(ffi.Pointer<Utf8> Function() fn) =>
    decodeNativeEnvelope(fn);

@visibleForTesting
TailscaleErrorCode parseTailscaleErrorCode(String? raw) =>
    parseNativeErrorCode(raw);

TailscaleStatus _loadStatusSnapshot() {
  try {
    final parsed =
        _callNativeJson(
              native.duneStatus,
              onError: TailscaleStatusException.new,
            )
            as Map<String, dynamic>;

    return TailscaleStatus.fromJson(parsed);
  } catch (error) {
    if (error is TailscaleStatusException) rethrow;
    throw TailscaleStatusException(
      'Failed to decode native Tailscale status.',
      cause: error,
    );
  }
}

List<TailscaleNode> _loadPeerSnapshot() {
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
    return TailscaleNode.listFromJson(decoded);
  } catch (error) {
    if (error is TailscaleStatusException) rethrow;
    throw TailscaleStatusException(
      'Failed to decode native Tailscale peers.',
      cause: error,
    );
  }
}

TailscalePrefs _parsePrefs(Map<String, dynamic> json) {
  try {
    return TailscalePrefs.fromJson(json);
  } catch (error) {
    throw TailscalePrefsException(
      'Failed to decode native Tailscale prefs.',
      cause: error,
    );
  }
}

TailscaleNodeIdentity? _parseWhoIsResponse(Map<String, dynamic> json) {
  if (json['found'] != true) return null;
  return TailscaleNodeIdentity.fromJson(json);
}

PingResult _parsePingResult(Map<String, dynamic> json) {
  final micros = (json['latencyMicros'] as num?)?.toInt() ?? 0;
  final path = switch (json['path'] as String?) {
    'direct' => PingPath.direct,
    'derp' => PingPath.derp,
    _ => PingPath.unknown,
  };
  return PingResult(
    latency: Duration(microseconds: micros),
    path: path,
    derpRegion: json['derpRegion'] as String?,
  );
}

DERPMap _parseDERPMap(Map<String, dynamic> json) {
  final rawRegions = json['regions'] as Map<String, dynamic>? ?? const {};
  final regions = <int, DERPRegion>{};
  rawRegions.forEach((id, value) {
    final regionId = int.tryParse(id);
    if (regionId == null || value is! Map<String, dynamic>) return;
    regions[regionId] = DERPRegion(
      regionId: (value['regionId'] as num?)?.toInt() ?? regionId,
      regionCode: value['regionCode'] as String? ?? '',
      regionName: value['regionName'] as String? ?? '',
      latitude: (value['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (value['longitude'] as num?)?.toDouble() ?? 0,
      avoid: value['avoid'] as bool? ?? false,
      noMeasureNoHome: value['noMeasureNoHome'] as bool? ?? false,
      nodes: ((value['nodes'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_parseDERPNode)
          .toList(growable: false),
    );
  });
  return DERPMap(
    regions: regions,
    omitDefaultRegions: json['omitDefaultRegions'] as bool? ?? false,
  );
}

DERPNode _parseDERPNode(Map<String, dynamic> n) => DERPNode(
  name: n['name'] as String? ?? '',
  hostName: n['hostName'] as String? ?? '',
  ipv4: n['ipv4'] as String?,
  ipv6: n['ipv6'] as String?,
  derpPort: (n['derpPort'] as num?)?.toInt() ?? 0,
  stunPort: (n['stunPort'] as num?)?.toInt() ?? 0,
  canPort80: n['canPort80'] as bool? ?? false,
);

ClientVersion? _parseClientVersion(Map<String, dynamic> json) {
  if (json['available'] != true) return null;
  return ClientVersion(
    latestVersion: json['latestVersion'] as String? ?? '',
    urgentSecurityUpdate: json['urgentSecurityUpdate'] as bool? ?? false,
    notifyText: json['notifyText'] as String?,
  );
}
