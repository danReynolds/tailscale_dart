import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../api/diag.dart';
import '../api/identity.dart';
import '../errors.dart';
import '../ffi_bindings.dart' as native;
import '../status.dart';

part 'messages.dart';
part 'entrypoint.dart';

/// The main isolate worker used by [Tailscale] to perform native Tailscale operations.
final class Worker {
  Worker({required this.publishState, required this.publishRuntimeError}) {
    _start();
  }

  final void Function(NodeState state) publishState;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;

  // Requests are processed synchronously on the worker isolate and each
  // command produces exactly one response in request order, so a FIFO queue is
  // sufficient for matching RPC responses without request IDs.
  final Queue<Completer<_WorkerResponse>> _pendingRequests =
      Queue<Completer<_WorkerResponse>>();

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
        publishRuntimeError(TailscaleRuntimeError(
          message: message,
          code: TailscaleRuntimeErrorCode.node,
        ));
        _dispose();
      case _WorkerRuntimeErrorEvent(:final error):
        publishRuntimeError(error);
      case _WorkerStateEvent(:final state):
        publishState(state);
      case _WorkerResponse():
        _pendingRequests.removeFirst().complete(message);
    }
  }

  void _dispose() {
    native.duneStopWatch();
    native.duneSetDartPort(0);
    native.duneStop();
    _receivePort.close();

    final error =
        const TailscaleOperationException('worker', 'Worker terminated.');

    if (!_sendPortCompleter.isCompleted) {
      _sendPortCompleter.completeError(error);
    }
    for (final c in _pendingRequests) {
      c.completeError(error);
    }
    _pendingRequests.clear();
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

  Future<({int proxyPort, String proxyAuthToken})> start({
    required String hostname,
    required String authKey,
    required String controlUrl,
    required String stateDir,
  }) async {
    final _WorkerStartResponse(:proxyPort, :proxyAuthToken) =
        await _request<_WorkerStartResponse>(
      _WorkerStartCommand(
        hostname: hostname,
        authKey: authKey,
        controlUrl: controlUrl,
        stateDir: stateDir,
      ),
    );
    return (proxyPort: proxyPort, proxyAuthToken: proxyAuthToken);
  }

  Future<int> listen({required int localPort, required int tailnetPort}) async {
    final response = await _request<_WorkerListenResponse>(
      _WorkerListenCommand(localPort: localPort, tailnetPort: tailnetPort),
    );
    return response.listenPort;
  }

  Future<({int loopbackPort, String token})> tcpDial({
    required String host,
    required int port,
    Duration? timeout,
  }) async {
    final response = await _request<_WorkerTcpDialResponse>(
      _WorkerTcpDialCommand(
        host: host,
        port: port,
        timeoutMillis: timeout?.inMilliseconds ?? 0,
      ),
    );
    return (loopbackPort: response.loopbackPort, token: response.token);
  }

  Future<int> tcpBind({
    required int tailnetPort,
    required String tailnetHost,
    required int loopbackPort,
  }) async {
    final response = await _request<_WorkerTcpBindResponse>(
      _WorkerTcpBindCommand(
        tailnetPort: tailnetPort,
        tailnetHost: tailnetHost,
        loopbackPort: loopbackPort,
      ),
    );
    return response.tailnetPort;
  }

  Future<void> tcpUnbind({required int loopbackPort}) async {
    await _request<_WorkerAckResponse>(
      _WorkerTcpUnbindCommand(loopbackPort: loopbackPort),
    );
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
