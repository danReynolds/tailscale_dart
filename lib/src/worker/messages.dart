part of 'worker.dart';

enum _WorkerOperation {
  start,
  listen,
  status,
  peers,
  down,
  logout;

  TailscaleException exceptionForMessage(String message) => switch (this) {
        start => TailscaleUpException(message),
        listen => TailscaleListenException(message),
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
