part of 'worker.dart';

enum _WorkerOperation {
  start,
  listen,
  tcpDial,
  tcpBind,
  tcpUnbind,
  tlsBind,
  udpBind,
  whois,
  tlsDomains,
  diagPing,
  diagMetrics,
  diagDERPMap,
  diagCheckUpdate,
  status,
  peers,
  down,
  logout;

  TailscaleException exceptionForMessage(String message) => switch (this) {
        start => TailscaleUpException(message),
        listen => TailscaleHttpException(message),
        tcpDial => TailscaleTcpException(message),
        tcpBind => TailscaleTcpException(message),
        tcpUnbind => TailscaleTcpException(message),
        tlsBind => TailscaleTlsException(message),
        udpBind => TailscaleUdpException(message),
        whois => TailscaleStatusException(message),
        tlsDomains => TailscaleTlsException(message),
        diagPing => TailscaleDiagException(message),
        diagMetrics => TailscaleDiagException(message),
        diagDERPMap => TailscaleDiagException(message),
        diagCheckUpdate => TailscaleDiagException(message),
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

final class _WorkerTcpDialCommand extends _WorkerCommand {
  const _WorkerTcpDialCommand({
    required this.host,
    required this.port,
    required this.timeoutMillis,
  }) : super(_WorkerOperation.tcpDial);

  final String host;
  final int port;
  final int timeoutMillis;
}

final class _WorkerTcpBindCommand extends _WorkerCommand {
  const _WorkerTcpBindCommand({
    required this.tailnetPort,
    required this.tailnetHost,
    required this.loopbackPort,
  }) : super(_WorkerOperation.tcpBind);

  final int tailnetPort;
  final String tailnetHost;
  final int loopbackPort;
}

final class _WorkerTcpBindResponse extends _WorkerResponse {
  const _WorkerTcpBindResponse({required this.tailnetPort})
      : super(_WorkerOperation.tcpBind);

  final int tailnetPort;
}

final class _WorkerTcpUnbindCommand extends _WorkerCommand {
  const _WorkerTcpUnbindCommand({required this.loopbackPort})
      : super(_WorkerOperation.tcpUnbind);

  final int loopbackPort;
}

final class _WorkerTlsBindCommand extends _WorkerCommand {
  const _WorkerTlsBindCommand({
    required this.tailnetPort,
    required this.loopbackPort,
  }) : super(_WorkerOperation.tlsBind);

  final int tailnetPort;
  final int loopbackPort;
}

final class _WorkerTlsBindResponse extends _WorkerResponse {
  const _WorkerTlsBindResponse({required this.tailnetPort})
      : super(_WorkerOperation.tlsBind);

  final int tailnetPort;
}

final class _WorkerUdpBindCommand extends _WorkerCommand {
  const _WorkerUdpBindCommand({
    required this.tailnetHost,
    required this.tailnetPort,
    required this.loopbackPort,
  }) : super(_WorkerOperation.udpBind);

  final String tailnetHost;
  final int tailnetPort;
  final int loopbackPort;
}

final class _WorkerUdpBindResponse extends _WorkerResponse {
  const _WorkerUdpBindResponse({required this.tailnetPort})
      : super(_WorkerOperation.udpBind);

  final int tailnetPort;
}

final class _WorkerWhoIsCommand extends _WorkerCommand {
  const _WorkerWhoIsCommand({required this.ip})
      : super(_WorkerOperation.whois);

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

sealed class _WorkerResponse extends _WorkerMainMessage {
  const _WorkerResponse(this.operation);

  final _WorkerOperation operation;
}

final class _WorkerStartResponse extends _WorkerResponse {
  const _WorkerStartResponse({
    required this.proxyPort,
    required this.proxyAuthToken,
  }) : super(_WorkerOperation.start);

  final int proxyPort;
  final String proxyAuthToken;
}

final class _WorkerListenResponse extends _WorkerResponse {
  const _WorkerListenResponse({required this.listenPort})
      : super(_WorkerOperation.listen);

  final int listenPort;
}

final class _WorkerTcpDialResponse extends _WorkerResponse {
  const _WorkerTcpDialResponse({
    required this.loopbackPort,
    required this.token,
  }) : super(_WorkerOperation.tcpDial);

  final int loopbackPort;
  final String token;
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

final class _WorkerWhoIsResponse extends _WorkerResponse {
  const _WorkerWhoIsResponse({required this.identity})
      : super(_WorkerOperation.whois);

  /// Null when LocalAPI reported the IP is not known on this tailnet.
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
  }) : super(operation);

  final String message;
}
