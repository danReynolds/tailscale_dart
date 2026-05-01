part of 'worker.dart';

enum _WorkerOperation {
  start,
  httpBind,
  httpCloseBinding,
  tcpDialFd,
  tcpListenFd,
  tcpCloseFdListener,
  tlsListenFd,
  udpBindFd,
  whois,
  tlsDomains,
  diagPing,
  diagMetrics,
  diagDERPMap,
  diagCheckUpdate,
  status,
  peers,
  prefsGet,
  prefsUpdate,
  exitNodeSuggest,
  exitNodeUseAuto,
  down,
  logout;

  TailscaleException exceptionForMessage(
    String message, {
    TailscaleErrorCode code = TailscaleErrorCode.unknown,
    int? statusCode,
  }) => switch (this) {
    start => TailscaleUpException(message, code: code, statusCode: statusCode),
    httpBind => TailscaleHttpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    httpCloseBinding => TailscaleHttpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tcpDialFd => TailscaleTcpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tcpListenFd => TailscaleTcpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tcpCloseFdListener => TailscaleTcpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tlsListenFd => TailscaleTlsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    udpBindFd => TailscaleUdpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    whois => TailscaleStatusException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tlsDomains => TailscaleTlsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    diagPing => TailscaleDiagException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    diagMetrics => TailscaleDiagException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    diagDERPMap => TailscaleDiagException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    diagCheckUpdate => TailscaleDiagException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    status => TailscaleStatusException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    peers => TailscaleStatusException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    prefsGet => TailscalePrefsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    prefsUpdate => TailscalePrefsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    exitNodeSuggest => TailscaleExitNodeException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    exitNodeUseAuto => TailscaleExitNodeException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    down => TailscaleOperationException(
      'down',
      message,
      code: code,
      statusCode: statusCode,
    ),
    logout => TailscaleLogoutException(
      message,
      code: code,
      statusCode: statusCode,
    ),
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
    required this.hostNetworkSnapshot,
  }) : super(_WorkerOperation.start);

  final String hostname;
  final String authKey;
  final String controlUrl;
  final String stateDir;
  final String hostNetworkSnapshot;
}

final class _WorkerHttpBindCommand extends _WorkerCommand {
  const _WorkerHttpBindCommand({required this.tailnetPort})
    : super(_WorkerOperation.httpBind);

  final int tailnetPort;
}

final class _WorkerHttpCloseBindingCommand extends _WorkerCommand {
  const _WorkerHttpCloseBindingCommand({required this.bindingId})
    : super(_WorkerOperation.httpCloseBinding);

  final int bindingId;
}

final class _WorkerTcpDialFdCommand extends _WorkerCommand {
  const _WorkerTcpDialFdCommand({
    required this.host,
    required this.port,
    required this.timeoutMillis,
  }) : super(_WorkerOperation.tcpDialFd);

  final String host;
  final int port;
  final int timeoutMillis;
}

final class _WorkerTcpListenFdCommand extends _WorkerCommand {
  const _WorkerTcpListenFdCommand({
    required this.tailnetPort,
    required this.tailnetHost,
  }) : super(_WorkerOperation.tcpListenFd);

  final int tailnetPort;
  final String tailnetHost;
}

final class _WorkerTcpCloseFdListenerCommand extends _WorkerCommand {
  const _WorkerTcpCloseFdListenerCommand({required this.listenerId})
    : super(_WorkerOperation.tcpCloseFdListener);

  final int listenerId;
}

final class _WorkerTlsListenFdCommand extends _WorkerCommand {
  const _WorkerTlsListenFdCommand({
    required this.tailnetPort,
    required this.tailnetHost,
  }) : super(_WorkerOperation.tlsListenFd);

  final int tailnetPort;
  final String tailnetHost;
}

final class _WorkerUdpBindFdCommand extends _WorkerCommand {
  const _WorkerUdpBindFdCommand({required this.host, required this.port})
    : super(_WorkerOperation.udpBindFd);

  final String host;
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

final class _WorkerStatusCommand extends _WorkerCommand {
  const _WorkerStatusCommand({required this.stateDir})
    : super(_WorkerOperation.status);

  final String stateDir;
}

final class _WorkerPeersCommand extends _WorkerCommand {
  const _WorkerPeersCommand() : super(_WorkerOperation.peers);
}

final class _WorkerPrefsGetCommand extends _WorkerCommand {
  const _WorkerPrefsGetCommand() : super(_WorkerOperation.prefsGet);
}

final class _WorkerPrefsUpdateCommand extends _WorkerCommand {
  const _WorkerPrefsUpdateCommand({required this.updateJson})
    : super(_WorkerOperation.prefsUpdate);

  final String updateJson;
}

final class _WorkerExitNodeSuggestCommand extends _WorkerCommand {
  const _WorkerExitNodeSuggestCommand()
    : super(_WorkerOperation.exitNodeSuggest);
}

final class _WorkerExitNodeUseAutoCommand extends _WorkerCommand {
  const _WorkerExitNodeUseAutoCommand()
    : super(_WorkerOperation.exitNodeUseAuto);
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

  final List<TailscaleNode> peers;
}

sealed class _WorkerResponse extends _WorkerMainMessage {
  const _WorkerResponse(this.operation);

  final _WorkerOperation operation;
}

final class _WorkerStartResponse extends _WorkerResponse {
  const _WorkerStartResponse() : super(_WorkerOperation.start);
}

final class _WorkerHttpBindResponse extends _WorkerResponse {
  const _WorkerHttpBindResponse({
    required this.bindingId,
    required this.tailnetAddress,
    required this.tailnetPort,
  }) : super(_WorkerOperation.httpBind);

  final int bindingId;
  final String tailnetAddress;
  final int tailnetPort;
}

final class _WorkerTcpDialFdResponse extends _WorkerResponse {
  const _WorkerTcpDialFdResponse({
    required this.fd,
    required this.localAddress,
    required this.localPort,
    required this.remoteAddress,
    required this.remotePort,
  }) : super(_WorkerOperation.tcpDialFd);

  final int fd;
  final String localAddress;
  final int localPort;
  final String remoteAddress;
  final int remotePort;
}

final class _WorkerTcpListenFdResponse extends _WorkerResponse {
  const _WorkerTcpListenFdResponse({
    required this.listenerId,
    required this.localAddress,
    required this.localPort,
  }) : super(_WorkerOperation.tcpListenFd);

  final int listenerId;
  final String localAddress;
  final int localPort;
}

final class _WorkerTlsListenFdResponse extends _WorkerResponse {
  const _WorkerTlsListenFdResponse({
    required this.listenerId,
    required this.localAddress,
    required this.localPort,
  }) : super(_WorkerOperation.tlsListenFd);

  final int listenerId;
  final String localAddress;
  final int localPort;
}

final class _WorkerUdpBindFdResponse extends _WorkerResponse {
  const _WorkerUdpBindFdResponse({
    required this.fd,
    required this.localAddress,
    required this.localPort,
  }) : super(_WorkerOperation.udpBindFd);

  final int fd;
  final String localAddress;
  final int localPort;
}

final class _WorkerStatusResponse extends _WorkerResponse {
  const _WorkerStatusResponse({required this.status})
    : super(_WorkerOperation.status);

  final TailscaleStatus status;
}

final class _WorkerPeersResponse extends _WorkerResponse {
  const _WorkerPeersResponse({required this.peers})
    : super(_WorkerOperation.peers);

  final List<TailscaleNode> peers;
}

final class _WorkerWhoIsResponse extends _WorkerResponse {
  const _WorkerWhoIsResponse({required this.identity})
    : super(_WorkerOperation.whois);

  /// Null when LocalAPI reported the IP is not known on this tailnet.
  final TailscaleNodeIdentity? identity;
}

final class _WorkerPrefsResponse extends _WorkerResponse {
  const _WorkerPrefsResponse({
    required _WorkerOperation operation,
    required this.prefs,
  }) : super(operation);

  final TailscalePrefs prefs;
}

final class _WorkerExitNodeSuggestResponse extends _WorkerResponse {
  const _WorkerExitNodeSuggestResponse({required this.nodeId})
    : super(_WorkerOperation.exitNodeSuggest);

  final String? nodeId;
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

  /// Null when the node is on the latest version.
  final ClientVersion? clientVersion;
}

final class _WorkerAckResponse extends _WorkerResponse {
  const _WorkerAckResponse(super.operation);
}

final class _WorkerFailureResponse extends _WorkerResponse {
  const _WorkerFailureResponse({
    required _WorkerOperation operation,
    required this.message,
    this.code = TailscaleErrorCode.unknown,
    this.statusCode,
  }) : super(operation);

  final String message;
  final TailscaleErrorCode code;
  final int? statusCode;
}
