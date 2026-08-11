part of 'worker.dart';

enum _WorkerOperation {
  start,
  httpCloseBinding,
  tcpCloseFdListener,
  udpCloseBinding,
  whois,
  tlsDomains,
  diagMetrics,
  diagDERPMap,
  diagCheckUpdate,
  debugNodeState,
  status,
  peers,
  prefsGet,
  prefsUpdate,
  exitNodeSuggest,
  exitNodeUseAuto,
  serveClear,
  funnelClear,
  down,
  logout;

  TailscaleException exceptionForMessage(
    String message, {
    TailscaleErrorCode code = TailscaleErrorCode.unknown,
    int? statusCode,
  }) => switch (this) {
    start => TailscaleUpException(message, code: code, statusCode: statusCode),
    httpCloseBinding => TailscaleHttpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tcpCloseFdListener => TailscaleTcpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    tlsDomains => TailscaleTlsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    udpCloseBinding => TailscaleUdpException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    whois || status || peers => TailscaleStatusException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    diagMetrics || diagDERPMap || diagCheckUpdate || debugNodeState =>
      TailscaleDiagException(message, code: code, statusCode: statusCode),
    prefsGet || prefsUpdate => TailscalePrefsException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    exitNodeSuggest || exitNodeUseAuto => TailscaleExitNodeException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    serveClear => TailscaleServeException(
      message,
      code: code,
      statusCode: statusCode,
    ),
    funnelClear => TailscaleFunnelException(
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
    required this.requestToken,
    required this.hostname,
    required this.authKey,
    required this.ephemeral,
    required this.controlUrl,
    required this.hostNetworkSnapshot,
    required this.bootstrapBudgetMillis,
  }) : super(_WorkerOperation.start);

  final int requestToken;
  final String hostname;
  final String authKey;
  final bool ephemeral;
  final String controlUrl;
  final String hostNetworkSnapshot;
  final int bootstrapBudgetMillis;
}

final class _WorkerHttpCloseBindingCommand extends _WorkerCommand {
  const _WorkerHttpCloseBindingCommand({required this.bindingId})
    : super(_WorkerOperation.httpCloseBinding);

  final int bindingId;
}

final class _WorkerTcpCloseFdListenerCommand extends _WorkerCommand {
  const _WorkerTcpCloseFdListenerCommand({required this.listenerId})
    : super(_WorkerOperation.tcpCloseFdListener);

  final int listenerId;
}

final class _WorkerUdpCloseBindingCommand extends _WorkerCommand {
  const _WorkerUdpCloseBindingCommand({required this.bindingId})
    : super(_WorkerOperation.udpCloseBinding);

  final int bindingId;
}

final class _WorkerWhoIsCommand extends _WorkerCommand {
  const _WorkerWhoIsCommand({required this.ip}) : super(_WorkerOperation.whois);

  final String ip;
}

final class _WorkerTlsDomainsCommand extends _WorkerCommand {
  const _WorkerTlsDomainsCommand() : super(_WorkerOperation.tlsDomains);
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

final class _WorkerDebugNodeStateCommand extends _WorkerCommand {
  const _WorkerDebugNodeStateCommand() : super(_WorkerOperation.debugNodeState);
}

final class _WorkerStatusCommand extends _WorkerCommand {
  const _WorkerStatusCommand() : super(_WorkerOperation.status);
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

final class _WorkerServeClearCommand extends _WorkerCommand {
  const _WorkerServeClearCommand({
    required this.payloadJson,
    required bool funnel,
  }) : super(
         funnel ? _WorkerOperation.funnelClear : _WorkerOperation.serveClear,
       );

  final String payloadJson;
}

final class _WorkerDownCommand extends _WorkerCommand {
  const _WorkerDownCommand({
    required this.runtimeToken,
    required this.terminateAfterNativeResult,
  }) : super(_WorkerOperation.down);

  final int runtimeToken;
  final bool terminateAfterNativeResult;
}

final class _WorkerLogoutCommand extends _WorkerCommand {
  const _WorkerLogoutCommand({
    required this.runtimeToken,
    required this.hostNetworkSnapshot,
    required this.terminateAfterNativeResult,
  }) : super(_WorkerOperation.logout);

  final int runtimeToken;
  final String hostNetworkSnapshot;
  final bool terminateAfterNativeResult;
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
  const _WorkerStateEvent({required this.runtimeToken, required this.state});

  final int runtimeToken;
  final NodeState state;
}

final class _WorkerRuntimeErrorEvent extends _WorkerEvent {
  const _WorkerRuntimeErrorEvent({
    required this.runtimeToken,
    required this.error,
  });

  final int runtimeToken;
  final TailscaleRuntimeError error;
}

/// One exact native runtime was already detached and drained by Go.
///
/// This is deliberately distinct from a worker exit: the control isolate is
/// healthy and remains reusable, so R3 worker-recovery must not quarantine the
/// already-closed generation a second time.
final class _WorkerRuntimeTerminatedEvent extends _WorkerEvent {
  const _WorkerRuntimeTerminatedEvent({
    required this.runtimeToken,
    required this.message,
    required this.code,
    required this.emitStopped,
    required this.cleanupFailed,
    required this.reportRuntimeError,
  });

  final int runtimeToken;
  final String message;
  final TailscaleErrorCode code;
  final bool emitStopped;
  final bool cleanupFailed;
  final bool reportRuntimeError;
}

final class _WorkerPeersEvent extends _WorkerEvent {
  const _WorkerPeersEvent({required this.runtimeToken, required this.peers});

  final int runtimeToken;
  final List<TailscaleNode> peers;
}

sealed class _WorkerResponse extends _WorkerMainMessage {
  const _WorkerResponse(this.operation);

  final _WorkerOperation operation;
}

final class _WorkerStartResponse extends _WorkerResponse {
  const _WorkerStartResponse({
    required this.alreadyActive,
    required this.runtimeToken,
  }) : super(_WorkerOperation.start);

  final bool alreadyActive;
  final int runtimeToken;
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

final class _WorkerDebugNodeStateResponse extends _WorkerResponse {
  const _WorkerDebugNodeStateResponse({required this.snapshot})
    : super(_WorkerOperation.debugNodeState);

  final NodeStateSnapshot snapshot;
}

final class _WorkerDiagCheckUpdateResponse extends _WorkerResponse {
  const _WorkerDiagCheckUpdateResponse({required this.clientVersion})
    : super(_WorkerOperation.diagCheckUpdate);

  /// Null when the node is on the latest version.
  final ClientVersion? clientVersion;
}

final class _WorkerAckResponse extends _WorkerResponse {
  const _WorkerAckResponse(
    super.operation, {
    this.runtimeToken = 0,
    this.matched = false,
    this.started = false,
    this.emitStopped = false,
    this.noState = false,
    this.cleanupFailed = false,
    this.errorMessage,
    this.errorCode = TailscaleErrorCode.unknown,
    this.statusCode,
  });

  final int runtimeToken;
  final bool matched;
  final bool started;
  final bool emitStopped;
  final bool noState;
  final bool cleanupFailed;
  final String? errorMessage;
  final TailscaleErrorCode errorCode;
  final int? statusCode;
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
