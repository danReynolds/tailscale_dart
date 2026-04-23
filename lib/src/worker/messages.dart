part of 'worker.dart';

enum _WorkerOperation {
  start,
  listen,
  attachTransport,
  tcpDial,
  tcpBind,
  tcpUnbind,
  udpBind,
  whois,
  tlsDomains,
  diagPing,
  diagMetrics,
  diagDERPMap,
  diagCheckUpdate,
  httpStartRequest,
  httpWriteBodyChunk,
  httpCloseRequestBody,
  httpCancelRequest,
  status,
  peers,
  down,
  logout;

  TailscaleException exceptionForMessage(String message) => switch (this) {
    start => TailscaleUpException(message),
    listen => TailscaleListenException(message),
    attachTransport => TailscaleUpException(message),
    tcpDial => TailscaleTcpDialException(message),
    tcpBind => TailscaleTcpBindException(message),
    tcpUnbind => TailscaleTcpBindException(message),
    udpBind => TailscaleUdpBindException(message),
    whois => TailscaleStatusException(message),
    tlsDomains => TailscaleStatusException(message),
    diagPing => TailscaleDiagException(message),
    diagMetrics => TailscaleDiagException(message),
    diagDERPMap => TailscaleDiagException(message),
    diagCheckUpdate => TailscaleDiagException(message),
    httpStartRequest => TailscaleHttpException(message),
    httpWriteBodyChunk => TailscaleHttpException(message),
    httpCloseRequestBody => TailscaleHttpException(message),
    httpCancelRequest => TailscaleHttpException(message),
    status => TailscaleStatusException(message),
    peers => TailscaleStatusException(message),
    down => TailscaleOperationException('down', message),
    logout => TailscaleLogoutException(message),
  };
}

sealed class _WorkerCommand {
  const _WorkerCommand(this.operation);

  final _WorkerOperation operation;
}

final class _WorkerStartCommand extends _WorkerCommand {
  const _WorkerStartCommand({
    required this.hostname,
    required this.authKey,
    required this.controlUrl,
    required this.stateDir,
  }) : super(_WorkerOperation.start);

  final String hostname;
  final String authKey;
  final String controlUrl;
  final String stateDir;
}

final class _WorkerListenCommand extends _WorkerCommand {
  const _WorkerListenCommand({
    required this.localPort,
    required this.tailnetPort,
  }) : super(_WorkerOperation.listen);

  final int localPort;
  final int tailnetPort;
}

final class _WorkerAttachTransportCommand extends _WorkerCommand {
  const _WorkerAttachTransportCommand({
    required this.host,
    required this.port,
    required this.listenerOwner,
  }) : super(_WorkerOperation.attachTransport);

  final String host;
  final int port;
  final String listenerOwner;
}

final class _WorkerTcpDialCommand extends _WorkerCommand {
  const _WorkerTcpDialCommand({required this.host, required this.port})
    : super(_WorkerOperation.tcpDial);

  final String host;
  final int port;
}

final class _WorkerTcpBindCommand extends _WorkerCommand {
  const _WorkerTcpBindCommand({required this.port})
    : super(_WorkerOperation.tcpBind);

  final int port;
}

final class _WorkerTcpUnbindCommand extends _WorkerCommand {
  const _WorkerTcpUnbindCommand({required this.port})
    : super(_WorkerOperation.tcpUnbind);

  final int port;
}

final class _WorkerUdpBindCommand extends _WorkerCommand {
  const _WorkerUdpBindCommand({required this.port})
    : super(_WorkerOperation.udpBind);

  final int port;
}

final class _WorkerWhoIsCommand extends _WorkerCommand {
  const _WorkerWhoIsCommand({required this.ip}) : super(_WorkerOperation.whois);

  final String ip;
}

final class _WorkerTlsDomainsCommand extends _WorkerCommand {
  const _WorkerTlsDomainsCommand() : super(_WorkerOperation.tlsDomains);
}

final class _WorkerDiagPingCommand extends _WorkerCommand {
  const _WorkerDiagPingCommand({
    required this.ip,
    required this.timeoutMillis,
    required this.pingType,
  }) : super(_WorkerOperation.diagPing);

  final String ip;
  final int timeoutMillis;
  final String pingType;
}

final class _WorkerDiagMetricsCommand extends _WorkerCommand {
  const _WorkerDiagMetricsCommand() : super(_WorkerOperation.diagMetrics);
}

final class _WorkerDiagDERPMapCommand extends _WorkerCommand {
  const _WorkerDiagDERPMapCommand() : super(_WorkerOperation.diagDERPMap);
}

final class _WorkerDiagCheckUpdateCommand extends _WorkerCommand {
  const _WorkerDiagCheckUpdateCommand()
    : super(_WorkerOperation.diagCheckUpdate);
}

final class _WorkerHttpStartRequestCommand extends _WorkerCommand {
  const _WorkerHttpStartRequestCommand({
    required this.requestId,
    required this.method,
    required this.url,
    required this.headers,
    required this.followRedirects,
    required this.maxRedirects,
    required this.persistentConnection,
  }) : super(_WorkerOperation.httpStartRequest);

  final int requestId;
  final String method;
  final String url;
  final Map<String, List<String>> headers;
  final bool followRedirects;
  final int maxRedirects;
  final bool persistentConnection;
}

final class _WorkerHttpWriteBodyChunkCommand extends _WorkerCommand {
  const _WorkerHttpWriteBodyChunkCommand({
    required this.requestId,
    required this.bodyBytes,
  }) : super(_WorkerOperation.httpWriteBodyChunk);

  final int requestId;
  final Uint8List bodyBytes;
}

final class _WorkerHttpCloseRequestBodyCommand extends _WorkerCommand {
  const _WorkerHttpCloseRequestBodyCommand({required this.requestId})
    : super(_WorkerOperation.httpCloseRequestBody);

  final int requestId;
}

final class _WorkerHttpCancelRequestCommand extends _WorkerCommand {
  const _WorkerHttpCancelRequestCommand({required this.requestId})
    : super(_WorkerOperation.httpCancelRequest);

  final int requestId;
}

final class _WorkerStatusCommand extends _WorkerCommand {
  const _WorkerStatusCommand({required this.stateDir})
    : super(_WorkerOperation.status);

  final String stateDir;
}

final class _WorkerPeersCommand extends _WorkerCommand {
  const _WorkerPeersCommand() : super(_WorkerOperation.peers);
}

final class _WorkerDownCommand extends _WorkerCommand {
  const _WorkerDownCommand() : super(_WorkerOperation.down);
}

final class _WorkerLogoutCommand extends _WorkerCommand {
  const _WorkerLogoutCommand({required this.stateDir})
    : super(_WorkerOperation.logout);

  final String stateDir;
}

sealed class _WorkerMainMessage {
  const _WorkerMainMessage();
}

final class _WorkerReadyMessage extends _WorkerMainMessage {
  const _WorkerReadyMessage(this.sendPort);

  final SendPort sendPort;
}

final class _WorkerBootstrapFailureMessage extends _WorkerMainMessage {
  const _WorkerBootstrapFailureMessage(this.message);

  final String message;
}

sealed class _WorkerEvent extends _WorkerMainMessage {
  const _WorkerEvent();
}

final class _WorkerStateEvent extends _WorkerEvent {
  const _WorkerStateEvent({required this.state});

  final NodeState state;
}

final class _WorkerRuntimeErrorEvent extends _WorkerEvent {
  const _WorkerRuntimeErrorEvent(this.error);

  final TailscaleRuntimeError error;
}

final class _WorkerPeersEvent extends _WorkerEvent {
  const _WorkerPeersEvent({required this.peers});

  final List<PeerStatus> peers;
}

final class _WorkerHttpResponseHeadEvent extends _WorkerEvent {
  const _WorkerHttpResponseHeadEvent({
    required this.requestId,
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    required this.isRedirect,
    required this.finalUrl,
    required this.reasonPhrase,
    required this.connectionClose,
  });

  final int requestId;
  final int statusCode;
  final Map<String, List<String>> headers;
  final int? contentLength;
  final bool isRedirect;
  final String finalUrl;
  final String reasonPhrase;
  final bool connectionClose;
}

final class _WorkerHttpResponseBodyEvent extends _WorkerEvent {
  const _WorkerHttpResponseBodyEvent({
    required this.requestId,
    required this.bytes,
  });

  final int requestId;
  final Uint8List bytes;
}

final class _WorkerHttpResponseDoneEvent extends _WorkerEvent {
  const _WorkerHttpResponseDoneEvent({required this.requestId});

  final int requestId;
}

final class _WorkerHttpResponseErrorEvent extends _WorkerEvent {
  const _WorkerHttpResponseErrorEvent({
    required this.requestId,
    required this.message,
  });

  final int requestId;
  final String message;
}

sealed class _WorkerResponse extends _WorkerMainMessage {
  const _WorkerResponse(this.operation);

  final _WorkerOperation operation;
}

final class _WorkerStartResponse extends _WorkerResponse {
  const _WorkerStartResponse({
    required this.transportMasterSecretB64,
    required this.transportSessionGenerationIdB64,
    required this.transportPreferredCarrierKind,
  }) : super(_WorkerOperation.start);

  final String? transportMasterSecretB64;
  final String? transportSessionGenerationIdB64;
  final String? transportPreferredCarrierKind;
}

final class _WorkerListenResponse extends _WorkerResponse {
  const _WorkerListenResponse({required this.listenPort})
    : super(_WorkerOperation.listen);

  final int listenPort;
}

final class _WorkerTcpDialResponse extends _WorkerResponse {
  const _WorkerTcpDialResponse({required this.streamId})
    : super(_WorkerOperation.tcpDial);

  final int streamId;
}

final class _WorkerUdpBindResponse extends _WorkerResponse {
  const _WorkerUdpBindResponse({required this.bindingId})
    : super(_WorkerOperation.udpBind);

  final int bindingId;
}

final class _WorkerWhoIsResponse extends _WorkerResponse {
  const _WorkerWhoIsResponse({required this.identity})
    : super(_WorkerOperation.whois);

  final PeerIdentity? identity;
}

final class _WorkerTlsDomainsResponse extends _WorkerResponse {
  const _WorkerTlsDomainsResponse({required this.domains})
    : super(_WorkerOperation.tlsDomains);

  final List<String> domains;
}

final class _WorkerDiagPingResponse extends _WorkerResponse {
  const _WorkerDiagPingResponse({required this.result})
    : super(_WorkerOperation.diagPing);

  final PingResult result;
}

final class _WorkerDiagMetricsResponse extends _WorkerResponse {
  const _WorkerDiagMetricsResponse({required this.metrics})
    : super(_WorkerOperation.diagMetrics);

  final String metrics;
}

final class _WorkerDiagDERPMapResponse extends _WorkerResponse {
  const _WorkerDiagDERPMapResponse({required this.map})
    : super(_WorkerOperation.diagDERPMap);

  final DERPMap map;
}

final class _WorkerDiagCheckUpdateResponse extends _WorkerResponse {
  const _WorkerDiagCheckUpdateResponse({required this.clientVersion})
    : super(_WorkerOperation.diagCheckUpdate);

  final ClientVersion? clientVersion;
}

final class _WorkerHttpStartRequestResponse extends _WorkerResponse {
  const _WorkerHttpStartRequestResponse({required this.requestId})
    : super(_WorkerOperation.httpStartRequest);

  final int requestId;
}

final class _WorkerStatusResponse extends _WorkerResponse {
  const _WorkerStatusResponse({required this.status})
    : super(_WorkerOperation.status);

  final TailscaleStatus status;
}

final class _WorkerPeersResponse extends _WorkerResponse {
  const _WorkerPeersResponse({required this.peers})
    : super(_WorkerOperation.peers);

  final List<PeerStatus> peers;
}

final class _WorkerAckResponse extends _WorkerResponse {
  const _WorkerAckResponse(super.operation);
}

final class _WorkerFailureResponse extends _WorkerResponse {
  const _WorkerFailureResponse({
    required _WorkerOperation operation,
    required this.message,
  }) : super(operation);

  final String message;
}
