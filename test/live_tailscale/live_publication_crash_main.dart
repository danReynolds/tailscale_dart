/// Subprocess harness for the persisted publication crash/restart receipt.
///
/// This intentionally uses production Keybay. It never installs the package's
/// test storage factory. The parent kills `publish` mode with SIGKILL, then
/// starts `restart` mode against the same state root and app identity without
/// an auth key.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keybay/keybay.dart';
import 'package:path/path.dart' as p;
import 'package:tailscale/src/keybay_state_custody.dart';
import 'package:tailscale/tailscale.dart';

// Keep native-backed resources strongly reachable until the helper exits.
final _retainedResources = <Object>[];

Future<void> main() async {
  final mode = _requiredEnv('MODE');
  final stateDir = _requiredEnv('STATE_DIR');
  final appId = _requiredEnv('APP_ID');
  final storage = SecretStorage(appId: deriveKeybayAppId(appId));
  final backend = await storage.backend.describe();
  if (!backend.available ||
      backend.locked ||
      !backend.capabilities.persistent) {
    throw StateError(
      'Production Keybay is not ready and persistent: '
      'scheme=${backend.scheme.name} available=${backend.available} '
      'locked=${backend.locked} persistent='
      '${backend.capabilities.persistent}',
    );
  }

  Tailscale.init(stateDir: stateDir, appId: appId);
  final tsnet = Tailscale.instance;

  if (mode == 'forget') {
    await _forget(tsnet, storage, stateDir);
    await _emit('FORGOTTEN', await _custodyReceipt(storage, backend));
    return;
  }
  if (mode != 'publish' && mode != 'restart') {
    throw StateError('Unknown MODE $mode.');
  }

  final hostname = _requiredEnv('HOSTNAME');
  final controlUrl = Platform.environment['CONTROL_URL'];
  final authKey = Platform.environment['AUTH_KEY'];
  final localPort = mode == 'publish'
      ? 0
      : int.parse(_requiredEnv('LOCAL_PORT'));
  final responseBody = _requiredEnv('RESPONSE_BODY');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, localPort);
  _retainedResources.add(server);
  var backendHits = 0;
  unawaited(
    _serveLoopback(
      server,
      responseBody,
      onRequest: mode == 'restart'
          ? () {
              backendHits++;
              unawaited(_emit('STALE_BACKEND_HIT', {'hits': backendHits}));
            }
          : null,
    ).catchError((_) {}),
  );

  StreamIterator<String>? commands;
  if (mode == 'restart') {
    commands = StreamIterator<String>(
      stdin.transform(utf8.decoder).transform(const LineSplitter()),
    );
    await _emit('SENTINEL_BOUND', <String, Object?>{
      ...await _custodyReceipt(storage, backend),
      'authKeyProvided': authKey != null && authKey.isNotEmpty,
      'localPort': server.port,
    });
    if (!await _waitForCommand(commands, 'START_UP')) {
      throw StateError('stdin closed before START_UP.');
    }
  }

  final running = Completer<void>();
  final states = <String>[];
  final subscription = tsnet.onStateChange.listen((state) {
    states.add(state.name);
    unawaited(_emit('STATE', {'state': state.name}));
    if (state == NodeState.running && !running.isCompleted) {
      running.complete();
    }
  });
  try {
    await tsnet.up(
      hostname: hostname,
      authKey: authKey == null || authKey.isEmpty ? null : authKey,
      ephemeral: false,
      controlUrl: controlUrl == null || controlUrl.isEmpty
          ? null
          : Uri.parse(controlUrl),
      timeout: const Duration(seconds: 120),
    );
    await running.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException(
        'persistent helper never reached package-level Running; states=$states',
      ),
    );
  } finally {
    await subscription.cancel();
  }

  final status = await tsnet.status();
  final ipv4 = status.ipv4;
  final stableNodeId = status.stableNodeId;
  if (ipv4 == null || stableNodeId == null) {
    throw StateError(
      'Running helper lacks persisted identity fields: '
      'ipv4=$ipv4 stableNodeId=$stableNodeId.',
    );
  }
  final common = <String, Object?>{
    ...await _custodyReceipt(storage, backend),
    'ipv4': ipv4,
    'stableNodeId': stableNodeId,
    'authKeyProvided': authKey != null && authKey.isNotEmpty,
    'localPort': server.port,
    'states': states,
  };
  if (mode == 'publish') {
    final tailnetPort = int.parse(_requiredEnv('TAILNET_PORT'));
    final path = _requiredEnv('PUBLICATION_PATH');
    final publication = await tsnet.serve.forward(
      tailnetPort: tailnetPort,
      localPort: server.port,
      path: path,
      https: false,
    );
    _retainedResources.add(publication);
    await _emit('PUBLISHED', <String, Object?>{
      ...common,
      'url': publication.url.toString(),
    });
    await Completer<void>().future;
  }

  // Restart mode deliberately performs no Serve/Funnel/TLS call. Its public
  // Running event is the proof boundary for the automatic first-Up reset.
  await _emit('RESTART_READY', common);
  while (await commands!.moveNext()) {
    switch (commands.current.trim()) {
      case 'REPORT_BACKEND':
        await _emit('BACKEND_REPORT', {'hits': backendHits});
      case 'FORGET':
        await _forget(tsnet, storage, stateDir);
        await server.close(force: true);
        _retainedResources.remove(server);
        await _emit('FORGOTTEN', await _custodyReceipt(storage, backend));
        await commands.cancel();
        // The package intentionally keeps its supervisor isolate available for
        // reuse. This one-shot harness has no further work after the flushed
        // cleanup receipt, so end it explicitly.
        exit(0);
    }
  }
  throw StateError('stdin closed before FORGET.');
}

Future<bool> _waitForCommand(
  StreamIterator<String> commands,
  String expected,
) async {
  while (await commands.moveNext()) {
    if (commands.current.trim() == expected) return true;
  }
  return false;
}

Future<void> _forget(
  Tailscale tsnet,
  SecretStorage storage,
  String stateDir,
) async {
  await tsnet.forgetLocalIdentity();
  if (await storage.containsKey(stateStoreDekEntry)) {
    throw StateError('forgetLocalIdentity left the Keybay DEK behind.');
  }
  final owned = Directory(p.join(stateDir, 'tailscale'));
  if (owned.existsSync()) {
    throw StateError('forgetLocalIdentity left ${owned.path} behind.');
  }
}

Future<void> _serveLoopback(
  HttpServer server,
  String body, {
  void Function()? onRequest,
}) async {
  await for (final request in server) {
    onRequest?.call();
    request.response.headers.contentType = ContentType.text;
    request.response.write(body);
    await request.response.close();
  }
}

Future<Map<String, Object?>> _custodyReceipt(
  SecretStorage storage,
  BackendInfo backend,
) async => <String, Object?>{
  'keybayScheme': backend.scheme.name,
  'keybayPersistent': backend.capabilities.persistent,
  'keybayLevel': backend.level?.name,
  'dekPresent': await storage.containsKey(stateStoreDekEntry),
};

Future<void> _emit(String prefix, Map<String, Object?> payload) async {
  // Native-asset build output can omit its final newline.
  stdout.write('\n$prefix ${jsonEncode(payload)}\n');
  await stdout.flush();
}

String _requiredEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('live_publication_crash: missing $name');
  }
  return value;
}
