import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../api/diag.dart';
import '../api/identity.dart';
import '../errors.dart';
import '../ffi_bindings.dart' as native;
import '../http_client.dart';
import '../runtime_transport_delegate.dart';
import '../status.dart';

part 'messages.dart';
part 'entrypoint.dart';

/// The main isolate worker used by [Tailscale] to perform native Tailscale operations.
final class Worker implements RuntimeTransportDelegate {
  Worker({
    required this.publishState,
    required this.publishRuntimeError,
    required this.publishPeers,
  }) {
    _start();
  }

  final void Function(NodeState state) publishState;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;
  final void Function(List<PeerStatus> peers) publishPeers;

  final Queue<Completer<_WorkerResponse>> _pendingRequests =
      Queue<Completer<_WorkerResponse>>();
  final Map<int, _PendingHttpRequest> _pendingHttpRequests =
      <int, _PendingHttpRequest>{};

  int _nextHttpRequestId = 1;

  final _sendPortCompleter = Completer<SendPort>();
  final _receivePort = ReceivePort();
  Future<SendPort> get _sendPort => _sendPortCompleter.future;

  Future<void> _start() async {
    _receivePort.listen(_handleWorkerMessage);
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _workerEntrypoint,
        _receivePort.sendPort,
      );
      isolate.addOnExitListener(_receivePort.sendPort);
    } catch (_) {
      _dispose();
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
        publishRuntimeError(
          TailscaleRuntimeError(
            message: message,
            code: TailscaleRuntimeErrorCode.node,
          ),
        );
        _dispose();
      case _WorkerRuntimeErrorEvent(:final error):
        publishRuntimeError(error);
      case _WorkerStateEvent(:final state):
        publishState(state);
      case _WorkerPeersEvent(:final peers):
        publishPeers(peers);
      case _WorkerHttpResponseHeadEvent event:
        _pendingHttpRequests[event.requestId]?.handleHead(event);
      case _WorkerHttpResponseBodyEvent event:
        _pendingHttpRequests[event.requestId]?.handleBody(event.bytes);
      case _WorkerHttpResponseDoneEvent event:
        _pendingHttpRequests.remove(event.requestId)?.handleDone();
      case _WorkerHttpResponseErrorEvent event:
        _pendingHttpRequests
            .remove(event.requestId)
            ?.handleError(TailscaleHttpException(event.message));
      case _WorkerResponse():
        _pendingRequests.removeFirst().complete(message);
    }
  }

  void _dispose() {
    native.duneStopWatch();
    native.duneSetDartPort(0);
    native.duneStop();
    _receivePort.close();

    final error = const TailscaleOperationException(
      'worker',
      'Worker terminated.',
    );

    if (!_sendPortCompleter.isCompleted) {
      _sendPortCompleter.completeError(error);
    }
    for (final c in _pendingRequests) {
      c.completeError(error);
    }
    _pendingRequests.clear();
    for (final request in _pendingHttpRequests.values) {
      request.handleError(error);
    }
    _pendingHttpRequests.clear();
  }

  Future<TResponse> _request<TResponse extends _WorkerResponse>(
    _WorkerCommand request,
  ) async {
    final sendPort = await _sendPort;
    final completer = Completer<_WorkerResponse>();
    _pendingRequests.addLast(completer);
    try {
      sendPort.send(request);
      final response = await completer.future;
      if (response is _WorkerFailureResponse) {
        throw response.operation.exceptionForMessage(response.message);
      }
      return response as TResponse;
    } catch (error) {
      _pendingRequests.remove(completer);
      rethrow;
    }
  }

  Future<
    ({
      String? transportMasterSecretB64,
      String? transportSessionGenerationIdB64,
      String? transportPreferredCarrierKind,
    })
  >
  start({
    required String hostname,
    required String authKey,
    required String controlUrl,
    required String stateDir,
  }) async {
    final _WorkerStartResponse(
      :transportMasterSecretB64,
      :transportSessionGenerationIdB64,
      :transportPreferredCarrierKind,
    ) = await _request<_WorkerStartResponse>(
      _WorkerStartCommand(
        hostname: hostname,
        authKey: authKey,
        controlUrl: controlUrl,
        stateDir: stateDir,
      ),
    );
    return (
      transportMasterSecretB64: transportMasterSecretB64,
      transportSessionGenerationIdB64: transportSessionGenerationIdB64,
      transportPreferredCarrierKind: transportPreferredCarrierKind,
    );
  }

  Future<int> listen({required int localPort, required int tailnetPort}) async {
    final response = await _request<_WorkerListenResponse>(
      _WorkerListenCommand(localPort: localPort, tailnetPort: tailnetPort),
    );
    return response.listenPort;
  }

  @override
  Future<void> attachTransport({
    required String host,
    required int port,
    required String listenerOwner,
  }) async {
    await _request<_WorkerAckResponse>(
      _WorkerAttachTransportCommand(
        host: host,
        port: port,
        listenerOwner: listenerOwner,
      ),
    );
  }

  Future<void> tcpBind({required int port}) async {
    await _request<_WorkerAckResponse>(_WorkerTcpBindCommand(port: port));
  }

  @override
  Future<void> tcpUnbind({required int port}) async {
    await _request<_WorkerAckResponse>(_WorkerTcpUnbindCommand(port: port));
  }

  @override
  Future<int> tcpDial({required String host, required int port}) async {
    final response = await _request<_WorkerTcpDialResponse>(
      _WorkerTcpDialCommand(host: host, port: port),
    );
    return response.streamId;
  }

  @override
  Future<int> udpBind({required int port}) async {
    final response = await _request<_WorkerUdpBindResponse>(
      _WorkerUdpBindCommand(port: port),
    );
    return response.bindingId;
  }

  Future<PeerIdentity?> whois(String ip) async {
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

  Future<PingResult> diagPing({
    required String ip,
    Duration? timeout,
    required String pingType,
  }) async {
    final response = await _request<_WorkerDiagPingResponse>(
      _WorkerDiagPingCommand(
        ip: ip,
        timeoutMillis: timeout?.inMilliseconds ?? 0,
        pingType: pingType,
      ),
    );
    return response.result;
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

  Future<TailscaleHttpStream> openHttpRequest(
    TailscaleHttpRequestHead request,
  ) async {
    final requestId = _nextHttpRequestId++;
    final pending = _PendingHttpRequest(requestId: requestId);
    _pendingHttpRequests[requestId] = pending;
    try {
      await _request<_WorkerHttpStartRequestResponse>(
        _WorkerHttpStartRequestCommand(
          requestId: requestId,
          method: request.method,
          url: request.url.toString(),
          headers: request.headers,
          followRedirects: request.followRedirects,
          maxRedirects: request.maxRedirects,
          persistentConnection: request.persistentConnection,
        ),
      );
      return TailscaleHttpStream(
        responseHead: pending.responseHead.future,
        responseBody: pending.responseBody.stream,
        sendBodyChunk: (bytes) =>
            _httpWriteBodyChunk(requestId: requestId, bytes: bytes),
        closeRequestBody: () => _httpCloseRequestBody(requestId: requestId),
        cancel: () => _httpCancelRequest(requestId: requestId),
      );
    } catch (_) {
      _pendingHttpRequests.remove(requestId);
      rethrow;
    }
  }

  Future<void> _httpWriteBodyChunk({
    required int requestId,
    required Uint8List bytes,
  }) async {
    await _request<_WorkerAckResponse>(
      _WorkerHttpWriteBodyChunkCommand(requestId: requestId, bodyBytes: bytes),
    );
  }

  Future<void> _httpCloseRequestBody({required int requestId}) async {
    await _request<_WorkerAckResponse>(
      _WorkerHttpCloseRequestBodyCommand(requestId: requestId),
    );
  }

  Future<void> _httpCancelRequest({required int requestId}) async {
    _pendingHttpRequests.remove(requestId)?.markCancelled();
    await _request<_WorkerAckResponse>(
      _WorkerHttpCancelRequestCommand(requestId: requestId),
    );
  }

  Future<TailscaleStatus> status({required String stateDir}) async {
    final response = await _request<_WorkerStatusResponse>(
      _WorkerStatusCommand(stateDir: stateDir),
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
}

final class _PendingHttpRequest {
  _PendingHttpRequest({required this.requestId});

  final int requestId;
  final Completer<TailscaleHttpResponseHead> responseHead =
      Completer<TailscaleHttpResponseHead>();
  final StreamController<Uint8List> responseBody = StreamController<Uint8List>(
    sync: true,
  );

  bool _cancelled = false;

  void handleHead(_WorkerHttpResponseHeadEvent event) {
    if (_cancelled || responseHead.isCompleted) {
      return;
    }
    responseHead.complete(
      TailscaleHttpResponseHead(
        statusCode: event.statusCode,
        headers: event.headers,
        contentLength: event.contentLength,
        isRedirect: event.isRedirect,
        finalUrl: Uri.parse(event.finalUrl),
        reasonPhrase: event.reasonPhrase,
        connectionClose: event.connectionClose,
      ),
    );
  }

  void handleBody(Uint8List bytes) {
    if (_cancelled || responseBody.isClosed) {
      return;
    }
    responseBody.add(bytes);
  }

  void handleDone() {
    if (!responseHead.isCompleted) {
      responseHead.completeError(
        const TailscaleHttpException(
          'HTTP response completed before response headers were delivered.',
        ),
      );
    }
    if (!responseBody.isClosed) {
      unawaited(responseBody.close());
    }
  }

  void handleError(Object error) {
    if (!responseHead.isCompleted) {
      responseHead.completeError(error);
    }
    if (!responseBody.isClosed) {
      responseBody.addError(error);
      unawaited(responseBody.close());
    }
  }

  void markCancelled() {
    _cancelled = true;
    if (!responseBody.isClosed) {
      unawaited(responseBody.close());
    }
  }
}
