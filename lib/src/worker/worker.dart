import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io' as io;

import 'package:ffi/ffi.dart';

import '../api/diag.dart';
import '../api/connection.dart';
import '../api/identity.dart';
import '../api/prefs.dart';
import '../errors.dart';
import '../ffi_bindings.dart' as native;
import '../status.dart';

part 'messages.dart';
part 'entrypoint.dart';

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

/// The main isolate worker used by [Tailscale] to perform native Tailscale operations.
final class Worker {
  Worker({
    required this.publishState,
    required this.publishRuntimeError,
    required this.publishNodes,
  }) {
    _start();
  }

  final void Function(NodeState state) publishState;
  final void Function(TailscaleRuntimeError error) publishRuntimeError;
  final void Function(List<TailscaleNode> nodes) publishNodes;

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
        publishNodes(peers);
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
        throw response.operation.exceptionForMessage(
          response.message,
          code: response.code,
          statusCode: response.statusCode,
        );
      }
      return response as TResponse;
    } catch (error) {
      _pendingRequests.remove(completer);
      rethrow;
    }
  }

  Future<void> start({
    required String hostname,
    required String authKey,
    required String controlUrl,
    required String stateDir,
  }) async {
    final hostNetworkSnapshot = await _loadHostNetworkSnapshot();
    await _request<_WorkerStartResponse>(
      _WorkerStartCommand(
        hostname: hostname,
        authKey: authKey,
        controlUrl: controlUrl,
        stateDir: stateDir,
        hostNetworkSnapshot: hostNetworkSnapshot,
      ),
    );
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

  Future<({int fd, TailscaleEndpoint local, TailscaleEndpoint remote})>
  tcpDialConnection({
    required String host,
    required int port,
    Duration? timeout,
  }) async {
    final response = await _request<_WorkerTcpDialFdResponse>(
      _WorkerTcpDialFdCommand(
        host: host,
        port: port,
        timeoutMillis: timeout?.inMilliseconds ?? 0,
      ),
    );
    return (
      fd: response.fd,
      local: TailscaleEndpoint(
        address: response.localAddress,
        port: response.localPort,
      ),
      remote: TailscaleEndpoint(
        address: response.remoteAddress,
        port: response.remotePort,
      ),
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

  Future<({int fd, TailscaleEndpoint local})> udpBindFd({
    required String host,
    required int port,
  }) async {
    final response = await _request<_WorkerUdpBindFdResponse>(
      _WorkerUdpBindFdCommand(host: host, port: port),
    );
    return (
      fd: response.fd,
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

  Future<
    ({
      Uri url,
      int port,
      String localAddress,
      int localPort,
      String path,
      bool https,
      bool funnel,
    })
  >
  serveForward({
    required int tailnetPort,
    required int localPort,
    required String localAddress,
    required String path,
    required bool https,
    required bool funnel,
  }) async {
    final payload = jsonEncode({
      'tailnetPort': tailnetPort,
      'localPort': localPort,
      'localAddress': localAddress,
      'path': path,
      'https': https,
      'funnel': funnel,
    });
    final response = await _request<_WorkerServePublicationResponse>(
      _WorkerServeForwardCommand(payloadJson: payload, funnel: funnel),
    );
    return (
      url: response.url,
      port: response.port,
      localAddress: response.localAddress,
      localPort: response.localPort,
      path: response.path,
      https: response.https,
      funnel: response.funnel,
    );
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

  Future<void> down() async {
    await _request<_WorkerAckResponse>(const _WorkerDownCommand());
  }

  Future<void> logout(String stateDir) async {
    await _request<_WorkerAckResponse>(
      _WorkerLogoutCommand(stateDir: stateDir),
    );
  }
}
