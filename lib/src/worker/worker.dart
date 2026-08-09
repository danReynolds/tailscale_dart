import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io' as io;

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../api/diag.dart';
import '../api/connection.dart';
import '../api/identity.dart';
import '../api/prefs.dart';
import '../errors.dart';
import '../ffi_bindings.dart' as native;
import '../status.dart';

part 'messages.dart';
part 'entrypoint.dart';
part 'native_offload.dart';

Future<String> _loadHostNetworkSnapshot() async {
  if (!io.Platform.isAndroid) {
    return '{}';
  }

  try {
    final interfaces = await io.NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: true,
      type: io.InternetAddressType.any,
    );
    final defaultRoute = _chooseDefaultRouteInterface(interfaces);
    return jsonEncode({
      'defaultRouteInterface': defaultRoute ?? '',
      'interfaces': [
        for (final iface in interfaces)
          {
            'name': iface.name,
            'index': iface.index,
            // dart:io doesn't expose MTU. Go will substitute a sane default.
            'mtu': 0,
            'addresses': [for (final addr in iface.addresses) addr.address],
          },
      ],
    });
  } catch (_) {
    // Go has an Android-only fallback that infers one outbound address. Passing
    // an empty snapshot still installs Tailscale's alternate netmon getter.
    return '{"interfaces":[]}';
  }
}

String? _chooseDefaultRouteInterface(List<io.NetworkInterface> interfaces) {
  String? ipv6Candidate;
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (!_isUsableHostAddress(addr)) continue;
      if (addr.type == io.InternetAddressType.IPv4) {
        return iface.name;
      }
      ipv6Candidate ??= iface.name;
    }
  }
  return ipv6Candidate;
}

bool _isUsableHostAddress(io.InternetAddress address) {
  if (address.isLoopback) return false;
  final bytes = address.rawAddress;
  if (address.type == io.InternetAddressType.IPv4) {
    return bytes.length == 4 && !(bytes[0] == 169 && bytes[1] == 254);
  }
  if (address.type == io.InternetAddressType.IPv6) {
    return bytes.length == 16 &&
        !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }
  return false;
}

@visibleForTesting
bool acceptsRuntimePush({
  required int token,
  required int? currentToken,
  required int? preparingToken,
}) {
  if (token <= 0) return false;
  return token == currentToken ||
      (currentToken == null && token == preparingToken);
}

/// Reserves lifecycle call order synchronously, before an operation reaches
/// its first asynchronous preparation step.
final class LifecycleQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;

    unawaited(() async {
      try {
        await previous;
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        done.complete();
      }
    }());
    return result.future;
  }
}

/// The main isolate worker used by [Tailscale] to perform native Tailscale operations.
final class Worker {
  Worker({
    required this.publishState,
    required this.publishRuntimeError,
    required this.publishNodes,
    required this.onExit,
    @visibleForTesting void Function(SendPort)? debugEntrypoint,
  }) : _entrypoint = debugEntrypoint ?? _workerEntrypoint {
    _start();
  }

  final void Function(NodeState state) publishState;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;
  final void Function(List<TailscaleNode> nodes) publishNodes;
  final void Function(
    Worker worker,
    int? runtimeToken,
    bool expected,
    Object? cause,
  )
  onExit;
  final void Function(SendPort) _entrypoint;

  // Requests are processed synchronously on the worker isolate and each
  // command produces exactly one response in request order, so a FIFO queue is
  // sufficient for matching RPC responses without request IDs.
  final Queue<Completer<_WorkerResponse>> _pendingRequests =
      Queue<Completer<_WorkerResponse>>();
  final LifecycleQueue _lifecycle = LifecycleQueue();

  final _sendPortCompleter = Completer<SendPort>();
  final _receivePort = ReceivePort();
  Future<SendPort> get _sendPort => _sendPortCompleter.future;

  /// Set once the worker isolate has terminated. After this, the cached
  /// `_sendPort` points at a dead port, so requests must fail fast rather than
  /// send into the void and hang on a completer nothing will ever complete.
  bool _disposed = false;
  bool _expectedExit = false;
  bool _logoutDispatched = false;
  bool _terminateOnNextShutdown = false;
  bool _terminateAfterNextStart = false;
  bool _terminateAfterNextLogoutDispatch = false;
  bool _terminateAfterNextLifecycleNativeResult = false;
  Isolate? _isolate;
  int? _runtimeToken;
  int? _preparingToken;

  int? get runtimeToken => _runtimeToken;
  bool get isDisposed => _disposed;

  static const _workerTerminated = TailscaleOperationException(
    'worker',
    'Worker terminated.',
    code: TailscaleErrorCode.workerTerminated,
  );

  Future<void> _start() async {
    _receivePort.listen(_handleWorkerMessage);
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _entrypoint,
        _receivePort.sendPort,
        // Register atomically with spawn. An isolate may exit before the
        // Future returned by spawn completes, in which case a later
        // addOnExitListener call is not guaranteed to receive an event.
        onExit: _receivePort.sendPort,
      );
      _isolate = isolate;
    } catch (error) {
      _dispose(cause: error);
    }
  }

  void _handleWorkerMessage(dynamic message) {
    if (message == null) {
      _dispose();
      return;
    }

    switch (message) {
      case _WorkerReadyMessage(:final sendPort):
        _sendPortCompleter.complete(sendPort);
      case _WorkerBootstrapFailureMessage(:final message):
        _dispose(
          cause: TailscaleOperationException(
            'worker bootstrap',
            message,
            code: TailscaleErrorCode.workerTerminated,
          ),
        );
      case _WorkerRuntimeErrorEvent(:final runtimeToken, :final error):
        if (!_acceptsPush(runtimeToken)) return;
        publishRuntimeError(error);
      case _WorkerStateEvent(:final runtimeToken, :final state):
        if (!_acceptsPush(runtimeToken)) return;
        publishState(state);
      case _WorkerPeersEvent(:final runtimeToken, :final peers):
        if (!_acceptsPush(runtimeToken)) return;
        publishNodes(peers);
      case _WorkerResponse():
        if (message
            case _WorkerAckResponse(:final operation, :final runtimeToken)
            when operation == _WorkerOperation.down ||
                operation == _WorkerOperation.logout) {
          // The caller isolate has now received the terminal disposition. The
          // native receipt must remain live until this exact boundary so a
          // worker exit before delivery can recover the same result.
          native.duneAcknowledgeLifecycle(runtimeToken);
        }
        // FIFO invariant: exactly one response per command, in order. Guard
        // against a stray/extra response so an invariant violation surfaces as
        // a dropped message rather than an unhandled throw in this listener.
        if (_pendingRequests.isEmpty) return;
        _pendingRequests.removeFirst().complete(message);
    }
  }

  bool _acceptsPush(int token) {
    return acceptsRuntimePush(
      token: token,
      currentToken: _runtimeToken,
      preparingToken: _preparingToken,
    );
  }

  void _dispose({Object? cause}) {
    if (_disposed) return;
    _disposed = true;
    _isolate = null;
    // Stop publishing to the dead isolate immediately. Runtime teardown and
    // watcher join belong to the token-qualified supervisor rescue path.
    native.duneSetDartPort(0);
    _receivePort.close();

    if (!_sendPortCompleter.isCompleted) {
      _sendPortCompleter.completeError(_workerTerminated);
    }
    for (final c in _pendingRequests) {
      c.completeError(_workerTerminated);
    }
    _pendingRequests.clear();
    onExit(this, _runtimeToken ?? _preparingToken, _expectedExit, cause);
  }

  /// Test seam for the expected/unexpected worker-exit supervisor paths.
  @internal
  void debugTerminate({bool expected = false}) {
    _expectedExit = expected;
    _isolate?.kill(priority: Isolate.immediate);
  }

  @internal
  Future<void> debugWaitUntilReady() async {
    await _sendPort;
  }

  @internal
  void debugTerminateOnNextShutdown() {
    _terminateOnNextShutdown = true;
  }

  @internal
  void debugTerminateAfterNextStart() {
    _terminateAfterNextStart = true;
  }

  @internal
  void debugTerminateAfterNextLogoutDispatch() {
    _terminateAfterNextLogoutDispatch = true;
  }

  @internal
  void debugTerminateAfterNextLifecycleNativeResult() {
    _terminateAfterNextLifecycleNativeResult = true;
  }

  void _terminateForDebugIfRequested() {
    if (!_terminateOnNextShutdown) return;
    _terminateOnNextShutdown = false;
    _isolate?.kill(priority: Isolate.immediate);
  }

  void detachRuntimeToken(int token) {
    if (_runtimeToken == token) _runtimeToken = null;
    if (_preparingToken == token) _preparingToken = null;
  }

  Future<TResponse> _request<TResponse extends _WorkerResponse>(
    _WorkerCommand request, {
    void Function()? afterSend,
  }) async {
    try {
      if (_disposed) throw _workerTerminated;
      final sendPort = await _sendPort;
      // The worker may have died while we awaited the (already-completed)
      // send port; if so the port is dead and a send would be silently dropped,
      // leaving the completer below to hang forever. Fail fast instead.
      if (_disposed) throw _workerTerminated;
      final completer = Completer<_WorkerResponse>();
      _pendingRequests.addLast(completer);
      sendPort.send(request);
      afterSend?.call();
      try {
        final response = await completer.future;
        if (response is _WorkerFailureResponse) {
          throw response.operation.exceptionForMessage(
            response.message,
            code: response.code,
            statusCode: response.statusCode,
          );
        }
        return response as TResponse;
      } finally {
        _pendingRequests.remove(completer);
      }
    } on TailscaleOperationException catch (error) {
      if (error.code == TailscaleErrorCode.workerTerminated) {
        throw request.operation.exceptionForMessage(
          error.message,
          code: error.code,
          statusCode: error.statusCode,
        );
      }
      rethrow;
    }
  }

  Future<WorkerStartResult> start({
    required int requestToken,
    required String hostname,
    required String authKey,
    required bool ephemeral,
    required String controlUrl,
  }) {
    _preparingToken = requestToken;
    return _lifecycle.run(() async {
      try {
        final hostNetworkSnapshot = await _loadHostNetworkSnapshot();
        if (_preparingToken != requestToken) {
          throw const TailscaleUpException(
            'Native startup was abandoned before dispatch.',
            code: TailscaleErrorCode.startupAbandoned,
          );
        }
        final response = await _request<_WorkerStartResponse>(
          _WorkerStartCommand(
            requestToken: requestToken,
            hostname: hostname,
            authKey: authKey,
            ephemeral: ephemeral,
            controlUrl: controlUrl,
            hostNetworkSnapshot: hostNetworkSnapshot,
          ),
        );
        if (_preparingToken != requestToken) {
          throw const TailscaleUpException(
            'Native startup completed after its request was abandoned.',
            code: TailscaleErrorCode.startupAbandoned,
          );
        }
        _runtimeToken = response.runtimeToken;
        if (_terminateAfterNextStart) {
          _terminateAfterNextStart = false;
          _isolate?.kill(priority: Isolate.immediate);
        }
        return WorkerStartResult(
          alreadyActive: response.alreadyActive,
          runtimeToken: response.runtimeToken,
        );
      } finally {
        if (_preparingToken == requestToken) _preparingToken = null;
      }
    });
  }

  Future<({int bindingId, TailscaleEndpoint tailnet})> httpBind({
    required int tailnetPort,
  }) async {
    final response = await _request<_WorkerHttpBindResponse>(
      _WorkerHttpBindCommand(tailnetPort: tailnetPort),
    );
    return (
      bindingId: response.bindingId,
      tailnet: TailscaleEndpoint(
        address: response.tailnetAddress,
        port: response.tailnetPort,
      ),
    );
  }

  Future<void> httpCloseBinding({required int bindingId}) async {
    await _request<_WorkerAckResponse>(
      _WorkerHttpCloseBindingCommand(bindingId: bindingId),
    );
  }

  Future<({int listenerId, TailscaleEndpoint local})> tcpListenFd({
    required int tailnetPort,
    required String tailnetHost,
  }) async {
    final response = await _request<_WorkerTcpListenFdResponse>(
      _WorkerTcpListenFdCommand(
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
      ),
    );
    return (
      listenerId: response.listenerId,
      local: TailscaleEndpoint(
        address: response.localAddress,
        port: response.localPort,
      ),
    );
  }

  Future<void> closeFdListener({required int listenerId}) async {
    await _request<_WorkerAckResponse>(
      _WorkerTcpCloseFdListenerCommand(listenerId: listenerId),
    );
  }

  Future<void> udpCloseBinding({required int bindingId}) async {
    await _request<_WorkerAckResponse>(
      _WorkerUdpCloseBindingCommand(bindingId: bindingId),
    );
  }

  Future<({int listenerId, TailscaleEndpoint local})> tlsListenFd({
    required int tailnetPort,
    required String tailnetHost,
  }) async {
    final response = await _request<_WorkerTlsListenFdResponse>(
      _WorkerTlsListenFdCommand(
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
      ),
    );
    return (
      listenerId: response.listenerId,
      local: TailscaleEndpoint(
        address: response.localAddress,
        port: response.localPort,
      ),
    );
  }

  Future<({int fd, int bindingId, TailscaleEndpoint local})> udpBindFd({
    required String host,
    required int port,
  }) async {
    final response = await _request<_WorkerUdpBindFdResponse>(
      _WorkerUdpBindFdCommand(host: host, port: port),
    );
    return (
      fd: response.fd,
      bindingId: response.bindingId,
      local: TailscaleEndpoint(
        address: response.localAddress,
        port: response.localPort,
      ),
    );
  }

  Future<TailscaleNodeIdentity?> whois(String ip) async {
    final response = await _request<_WorkerWhoIsResponse>(
      _WorkerWhoIsCommand(ip: ip),
    );
    return response.identity;
  }

  Future<List<String>> tlsDomains() async {
    final response = await _request<_WorkerTlsDomainsResponse>(
      const _WorkerTlsDomainsCommand(),
    );
    return response.domains;
  }

  Future<String> diagMetrics() async {
    final response = await _request<_WorkerDiagMetricsResponse>(
      const _WorkerDiagMetricsCommand(),
    );
    return response.metrics;
  }

  Future<DERPMap> diagDERPMap() async {
    final response = await _request<_WorkerDiagDERPMapResponse>(
      const _WorkerDiagDERPMapCommand(),
    );
    return response.map;
  }

  Future<ClientVersion?> diagCheckUpdate() async {
    final response = await _request<_WorkerDiagCheckUpdateResponse>(
      const _WorkerDiagCheckUpdateCommand(),
    );
    return response.clientVersion;
  }

  Future<NodeStateSnapshot> debugNodeState() async {
    final response = await _request<_WorkerDebugNodeStateResponse>(
      const _WorkerDebugNodeStateCommand(),
    );
    return response.snapshot;
  }

  Future<TailscaleStatus> status() async {
    final response = await _request<_WorkerStatusResponse>(
      const _WorkerStatusCommand(),
    );
    return response.status;
  }

  Future<List<TailscaleNode>> nodes() async {
    final response = await _request<_WorkerPeersResponse>(
      const _WorkerPeersCommand(),
    );
    return response.peers;
  }

  Future<TailscalePrefs> prefsGet() async {
    final response = await _request<_WorkerPrefsResponse>(
      const _WorkerPrefsGetCommand(),
    );
    return response.prefs;
  }

  Future<TailscalePrefs> prefsUpdate(PrefsUpdate update) async {
    final response = await _request<_WorkerPrefsResponse>(
      _WorkerPrefsUpdateCommand(updateJson: jsonEncode(update.toJson())),
    );
    return response.prefs;
  }

  Future<String?> exitNodeSuggest() async {
    final response = await _request<_WorkerExitNodeSuggestResponse>(
      const _WorkerExitNodeSuggestCommand(),
    );
    return response.nodeId;
  }

  Future<void> exitNodeUseAuto() async {
    await _request<_WorkerAckResponse>(const _WorkerExitNodeUseAutoCommand());
  }

  Future<void> serveClear({
    required int tailnetPort,
    required String path,
    required bool funnel,
  }) async {
    final payload = jsonEncode({
      'tailnetPort': tailnetPort,
      'path': path,
      'funnel': funnel,
    });
    await _request<_WorkerAckResponse>(
      _WorkerServeClearCommand(payloadJson: payload, funnel: funnel),
    );
  }

  Future<WorkerCloseResult> down() {
    final token = _runtimeToken ?? 0;
    final terminateAfterNativeResult = _terminateAfterNextLifecycleNativeResult;
    _terminateAfterNextLifecycleNativeResult = false;
    _expectedExit = token > 0;
    _terminateForDebugIfRequested();
    return _lifecycle.run(() async {
      try {
        final response = await _request<_WorkerAckResponse>(
          _WorkerDownCommand(
            runtimeToken: token,
            terminateAfterNativeResult: terminateAfterNativeResult,
          ),
        );
        if (response.matched && _runtimeToken == token) {
          _runtimeToken = null;
        }
        final errorMessage = response.errorMessage;
        return WorkerCloseResult(
          runtimeToken: response.runtimeToken,
          matched: response.matched,
          started: response.started,
          noState: response.noState,
          cleanupFailed: response.cleanupFailed,
          error: errorMessage == null
              ? null
              : TailscaleOperationException(
                  'down',
                  errorMessage,
                  code: response.errorCode,
                  statusCode: response.statusCode,
                ),
        );
      } finally {
        if (!_disposed) _expectedExit = false;
      }
    });
  }

  Future<WorkerCloseResult> logout({required int requestToken}) {
    final token = _runtimeToken ?? requestToken;
    _preparingToken = token;
    _expectedExit = token > 0;
    _terminateForDebugIfRequested();
    return _lifecycle.run(() async {
      try {
        final hostNetworkSnapshot = await _loadHostNetworkSnapshot();
        if (_preparingToken != token) {
          throw const TailscaleLogoutException(
            'Logout runtime preparation was abandoned before dispatch.',
            code: TailscaleErrorCode.startupAbandoned,
          );
        }
        final terminateAfterDispatch = _terminateAfterNextLogoutDispatch;
        _terminateAfterNextLogoutDispatch = false;
        final terminateAfterNativeResult =
            _terminateAfterNextLifecycleNativeResult;
        _terminateAfterNextLifecycleNativeResult = false;
        final response = await _request<_WorkerAckResponse>(
          _WorkerLogoutCommand(
            runtimeToken: token,
            hostNetworkSnapshot: hostNetworkSnapshot,
            terminateAfterNativeResult: terminateAfterNativeResult,
          ),
          afterSend: () {
            // Set this only after SendPort.send returns. A worker failure while
            // waiting for its port is known not to have reached native logout
            // and must remain workerTerminated, not logoutIndeterminate.
            _logoutDispatched = true;
            if (terminateAfterDispatch) {
              _isolate?.kill(priority: Isolate.immediate);
            }
          },
        );
        if ((response.started || response.noState) && _runtimeToken == token) {
          _runtimeToken = null;
        }
        final errorMessage = response.errorMessage;
        return WorkerCloseResult(
          runtimeToken: response.runtimeToken,
          matched: response.matched,
          started: response.started,
          noState: response.noState,
          cleanupFailed: response.cleanupFailed,
          error: errorMessage == null
              ? null
              : TailscaleLogoutException(
                  errorMessage,
                  code: response.errorCode,
                  statusCode: response.statusCode,
                ),
        );
      } on TailscaleLogoutException catch (error) {
        if (error.code == TailscaleErrorCode.workerTerminated &&
            _logoutDispatched) {
          throw TailscaleLogoutException(
            'The worker terminated after logout dispatch; the remote result '
            'is indeterminate.',
            code: TailscaleErrorCode.logoutIndeterminate,
            cause: error,
          );
        }
        if (error.code == TailscaleErrorCode.logoutIndeterminate &&
            _runtimeToken == token) {
          _runtimeToken = null;
        }
        rethrow;
      } finally {
        if (_preparingToken == token) _preparingToken = null;
        if (!_disposed) {
          _expectedExit = false;
          _logoutDispatched = false;
        }
      }
    });
  }
}

final class WorkerStartResult {
  const WorkerStartResult({
    required this.alreadyActive,
    required this.runtimeToken,
  });

  final bool alreadyActive;
  final int runtimeToken;
}

final class WorkerCloseResult {
  const WorkerCloseResult({
    required this.runtimeToken,
    required this.matched,
    required this.started,
    required this.noState,
    required this.cleanupFailed,
    required this.error,
  });

  final int runtimeToken;
  final bool matched;
  final bool started;
  final bool noState;
  final bool cleanupFailed;
  final TailscaleOperationException? error;
}
