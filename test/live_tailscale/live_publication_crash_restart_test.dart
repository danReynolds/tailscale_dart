/// Hosted receipt for stale ServeConfig cleanup across real process death.
///
/// This test uses production macOS Keybay, a persistent Tailscale node, and
/// SIGKILL. The replacement process reopens the same identity without an auth
/// key and performs only ordinary `up()` before reporting package Running.
@TestOn('mac-os')
@Tags(['live-tailscale'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import '../e2e/support/native_asset_warmup.dart';
import 'support/tailscale_api.dart';

const _appId = 'dev.tailscale.dart.live.crashReceipt';
const _observerAppId = 'dev.tailscale.dart.live.crashReceipt.observer';
const _hostnamePrefix = 'dune-live-crash-receipt';
const _publisherHostname = _hostnamePrefix;
const _observerHostname = '$_hostnamePrefix-observer';
const _tailnetPort = 18080;
const _publicationPath = '/crash-receipt';
const _publishedBody = 'publication before process crash';
const _replacementBody = 'stale publication survived restart';

void main() {
  final apiKey = Platform.environment['TAILSCALE_API_KEY'];
  final tailnetId = Platform.environment['TAILSCALE_TAILNET_ID'];
  final controlUrl = Platform.environment['TAILSCALE_CONTROL_URL'];
  if (apiKey == null ||
      apiKey.isEmpty ||
      tailnetId == null ||
      tailnetId.isEmpty) {
    test(
      'persistent crash/restart publication cleanup',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  LiveTailscaleApi? api;
  Directory? stateRoot;
  Directory? observerRoot;
  RandomAccessFile? runLock;
  _HelperProcess? publisher;
  _HelperProcess? replacement;
  Tailscale? observerNode;
  _ContinuousTailnetObserver? observer;
  final deviceIdsToDelete = <String>{};
  final authKeyIdsToDelete = <String>{};

  Uri? controlUri() {
    if (controlUrl == null || controlUrl.isEmpty) return null;
    return Uri.parse(controlUrl);
  }

  Future<LiveTailscaleAuthKey> issueAuthKey({required bool ephemeral}) async {
    final issued = await api!.createTrackedAuthKey(ephemeral: ephemeral);
    authKeyIdsToDelete.add(issued.id);
    return issued;
  }

  tearDownAll(() async {
    final errors = <String>[];

    await _captureCleanup(errors, 'stop observer probes', () async {
      await observer?.stop();
    });
    await _captureCleanup(errors, 'stop observer node', () async {
      await observerNode?.down();
    });
    await _captureCleanup(errors, 'terminate replacement helper', () async {
      await replacement?.terminate();
    });
    await _captureCleanup(errors, 'terminate publisher helper', () async {
      await publisher?.terminate();
    });

    var custodyClean = false;
    final root = stateRoot;
    if (root != null) {
      await _captureCleanup(
        errors,
        'forget persistent local identity',
        () async {
          await _runForget(stateDir: root.path, controlUrl: controlUrl);
          custodyClean = true;
        },
      );
      if (custodyClean) {
        await _captureCleanup(errors, 'delete persistent state root', () async {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });
      } else {
        stderr.writeln(
          'Preserving failed crash-receipt state for recovery at ${root.path} '
          '(appId=$_appId).',
        );
      }
    }

    final scratch = observerRoot;
    if (scratch != null) {
      await _captureCleanup(errors, 'delete observer state root', () async {
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      });
    }

    final liveApi = api;
    if (liveApi != null) {
      for (final id in deviceIdsToDelete) {
        await _captureCleanup(errors, 'delete device $id', () async {
          await liveApi.deleteDevice(id);
        });
      }
      await _captureCleanup(
        errors,
        'sweep reserved crash-receipt devices',
        () async {
          await _deleteReservedDevices(liveApi);
        },
      );
      for (final id in authKeyIdsToDelete) {
        await _captureCleanup(errors, 'revoke auth key $id', () async {
          await liveApi.deleteAuthKey(id);
        });
      }
      liveApi.close();
    }

    await _captureCleanup(errors, 'release local receipt lock', () async {
      await runLock?.unlock();
      await runLock?.close();
    });

    if (errors.isNotEmpty) {
      fail('Crash/restart receipt cleanup failed:\n${errors.join('\n')}');
    }
  });

  test(
    'SIGKILL then ordinary up clears stale publication before Running',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();
      final lockFile = File(
        p.join(
          Directory.systemTemp.path,
          'tailscale_dart_live_crash_receipt.lock',
        ),
      );
      runLock = lockFile.openSync(mode: FileMode.append);
      await runLock!.lock(FileLock.exclusive);

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateRoot = Directory(
        p.join(
          Directory.systemTemp.path,
          'tailscale_dart_live_crash_receipt_state',
        ),
      );

      // The app ID and state root are a stable pair. This recovers both sides
      // of custody after an interrupted local run instead of orphaning old
      // ciphertext by pairing a fixed Keybay namespace with a random root.
      await _runForget(stateDir: stateRoot!.path, controlUrl: controlUrl);
      if (stateRoot!.existsSync()) stateRoot!.deleteSync(recursive: true);
      stateRoot!.createSync(recursive: true);
      await _deleteReservedDevices(api!);

      final publisherKey = await issueAuthKey(ephemeral: false);
      publisher = await _startHelper(
        mode: 'publish',
        stateDir: stateRoot!.path,
        hostname: _publisherHostname,
        controlUrl: controlUrl,
        authKey: publisherKey.key,
        responseBody: _publishedBody,
      );
      final published = await publisher!.waitForJson('PUBLISHED');
      _expectProductionKeybay(published, dekPresent: true);
      expect(published['authKeyProvided'], isTrue);

      final publicationUrl = Uri.parse(published['url']! as String);
      expect(publicationUrl.scheme, 'http');
      expect(publicationUrl.port, _tailnetPort);
      expect(publicationUrl.path, _publicationPath);
      final localPort = published['localPort']! as int;
      final initialIpv4 = published['ipv4']! as String;
      final initialStableNodeId = published['stableNodeId']! as String;
      expect(published['states'], contains(NodeState.running.name));
      final publisherDevice = await api!.waitForDevice(
        hostname: _publisherHostname,
        ipv4: initialIpv4,
      );
      deviceIdsToDelete.add(publisherDevice.id);
      await api!.deleteAuthKey(publisherKey.id);
      authKeyIdsToDelete.remove(publisherKey.id);

      observerRoot = Directory.systemTemp.createTempSync(
        'tailscale_live_crash_observer_',
      );
      final observerKey = await issueAuthKey(ephemeral: true);
      final observerRunId = DateTime.now().microsecondsSinceEpoch.toRadixString(
        36,
      );
      Tailscale.init(
        stateDir: observerRoot!.path,
        appId: '$_observerAppId.$observerRunId',
      );
      observerNode = Tailscale.instance;
      final observerStatus = await _upAndWaitRunning(
        observerNode!,
        hostname: _observerHostname,
        authKey: observerKey.key,
        controlUrl: controlUri(),
      );
      expect(observerStatus.ipv4, isNotNull);
      final observerDevice = await api!.waitForDevice(
        hostname: _observerHostname,
        ipv4: observerStatus.ipv4,
      );
      deviceIdsToDelete.add(observerDevice.id);
      await api!.deleteAuthKey(observerKey.id);
      authKeyIdsToDelete.remove(observerKey.id);

      observer = _ContinuousTailnetObserver(
        tsnet: observerNode!,
        targetIpv4: initialIpv4,
        hostHeader: publicationUrl.host,
        path: publicationUrl.path,
        tailnetPort: _tailnetPort,
      );
      await observer!.startAndWaitForBaseline();

      await publisher!.crash();
      publisher = null;

      replacement = await _startHelper(
        mode: 'restart',
        stateDir: stateRoot!.path,
        hostname: _publisherHostname,
        controlUrl: controlUrl,
        localPort: localPort,
        responseBody: _replacementBody,
      );
      final bound = await replacement!.waitForJson('SENTINEL_BOUND');
      _expectProductionKeybay(bound, dekPresent: true);
      expect(bound['authKeyProvided'], isFalse);
      expect(bound['localPort'], localPort);

      // Ensure the already-authenticated observer is actively probing before
      // the replacement is allowed to call up().
      observer!.arm();
      await observer!.waitForCompletedArmedAttempts(1);
      await replacement!.send('START_UP');
      final restarted = await replacement!.waitForJson('RESTART_READY');
      _expectProductionKeybay(restarted, dekPresent: true);
      expect(restarted['authKeyProvided'], isFalse);
      expect(restarted['states'], contains(NodeState.running.name));
      expect(restarted['ipv4'], initialIpv4);
      expect(restarted['stableNodeId'], initialStableNodeId);
      final restartedDevice = await api!.waitForDevice(
        hostname: _publisherHostname,
        ipv4: initialIpv4,
      );
      expect(
        restartedDevice.id,
        publisherDevice.id,
        reason: 'Restart without an auth key must reopen the persisted node.',
      );
      final restartPing = await observerNode!.diag.ping(
        initialIpv4,
        type: PingType.tsmp,
        timeout: const Duration(seconds: 10),
      );
      expect(restartPing.latency, greaterThan(Duration.zero));
      stdout.writeln(
        'RESTART_PING ${jsonEncode(<String, Object?>{'latencyMicros': restartPing.latency.inMicroseconds, 'path': restartPing.path.name})}',
      );

      // Cover the full startup interval plus a post-Running data-plane window,
      // then join the final raw-TCP probe before reading the backend counter.
      await Future<void>.delayed(const Duration(seconds: 3));
      final observation = await observer!.stop();
      stdout.writeln('OBSERVER_REPORT ${jsonEncode(observation.toJson())}');
      expect(observation.nodeState, NodeState.running);
      expect(observation.attempts, greaterThan(1));
      expect(observation.responses + observation.errors, observation.attempts);
      expect(
        observation.staleResponses,
        0,
        reason: 'The persistent observer received the replacement body.',
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await replacement!.send('REPORT_BACKEND');
      final backend = await replacement!.waitForJson('BACKEND_REPORT');
      expect(
        backend['hits'],
        0,
        reason:
            'The replacement loopback server received traffic through stale '
            'ServeConfig before or after package Running.',
      );

      await observerNode!.down();
      observerNode = null;

      await replacement!.send('FORGET');
      final forgotten = await replacement!.waitForJson('FORGOTTEN');
      _expectProductionKeybay(forgotten, dekPresent: false);
      await replacement!.expectExit(0);
      replacement = null;
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

void _expectProductionKeybay(
  Map<String, Object?> receipt, {
  required bool dekPresent,
}) {
  expect(receipt['keybayPersistent'], isTrue);
  expect(receipt['keybayScheme'], anyOf('encryptedFile', 'nativeItems'));
  expect(receipt['dekPresent'], dekPresent);
}

Future<void> _runForget({
  required String stateDir,
  required String? controlUrl,
}) async {
  final helper = await _startHelper(
    mode: 'forget',
    stateDir: stateDir,
    controlUrl: controlUrl,
  );
  try {
    final receipt = await helper.waitForJson('FORGOTTEN');
    _expectProductionKeybay(receipt, dekPresent: false);
    await helper.expectExit(0);
  } finally {
    await helper.terminate();
  }
}

Future<void> _deleteReservedDevices(LiveTailscaleApi api) async {
  final reserved = (await api.listDevices()).where((device) {
    final hostname = device.hostname.toLowerCase();
    final name = device.name.toLowerCase();
    return hostname.startsWith(_hostnamePrefix) ||
        name.startsWith(_hostnamePrefix);
  }).toList();
  for (final device in reserved) {
    await api.deleteDevice(device.id);
  }
}

Future<void> _captureCleanup(
  List<String> errors,
  String label,
  Future<void> Function() cleanup,
) async {
  try {
    await cleanup();
  } catch (error) {
    errors.add('$label: $error');
  }
}

Future<TailscaleStatus> _upAndWaitRunning(
  Tailscale tsnet, {
  required String hostname,
  required String authKey,
  required Uri? controlUrl,
}) async {
  final running = Completer<void>();
  final states = <NodeState>[];
  final subscription = tsnet.onStateChange.listen((state) {
    states.add(state);
    if (state == NodeState.running && !running.isCompleted) {
      running.complete();
    }
  });
  try {
    await tsnet.up(
      hostname: hostname,
      authKey: authKey,
      ephemeral: true,
      controlUrl: controlUrl,
      timeout: const Duration(seconds: 120),
    );
    await running.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException(
        'Observer never reached package Running; states=$states.',
      ),
    );
    return await tsnet.status();
  } finally {
    await subscription.cancel();
  }
}

Future<_HelperProcess> _startHelper({
  required String mode,
  required String stateDir,
  String? hostname,
  String? controlUrl,
  String? authKey,
  int? localPort,
  String? responseBody,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      '--enable-experiment=native-assets',
      'test/live_tailscale/live_publication_crash_main.dart',
    ],
    environment: <String, String>{
      ...Platform.environment,
      // The helper receives only the credential explicitly needed by its
      // mode. In particular, restart cannot fall back to ambient tsnet auth.
      'TAILSCALE_API_KEY': '',
      'TAILSCALE_TAILNET_ID': '',
      'TAILSCALE_AUTH_KEY': '',
      'TS_AUTHKEY': '',
      'TS_AUTH_KEY': '',
      'TSNET_FORCE_LOGIN': '',
      'MODE': mode,
      'STATE_DIR': stateDir,
      'APP_ID': _appId,
      'HOSTNAME': ?hostname,
      if (controlUrl != null && controlUrl.isNotEmpty)
        'CONTROL_URL': controlUrl,
      'AUTH_KEY': authKey ?? '',
      if (localPort != null) 'LOCAL_PORT': '$localPort',
      'RESPONSE_BODY': ?responseBody,
      if (mode == 'publish') ...<String, String>{
        'TAILNET_PORT': '$_tailnetPort',
        'PUBLICATION_PATH': _publicationPath,
      },
    },
  );
  return _HelperProcess(process, mode);
}

final class _ContinuousTailnetObserver {
  _ContinuousTailnetObserver({
    required this.tsnet,
    required this.targetIpv4,
    required this.hostHeader,
    required this.path,
    required this.tailnetPort,
  });

  final Tailscale tsnet;
  final String targetIpv4;
  final String hostHeader;
  final String path;
  final int tailnetPort;
  final _baseline = Completer<void>();
  Future<void>? _loop;
  Future<_ProbeReport>? _stopFuture;
  var _stopping = false;
  var _armed = false;
  var _nonce = 0;
  var _attempts = 0;
  var _responses = 0;
  var _errors = 0;
  var _staleResponses = 0;

  Future<void> startAndWaitForBaseline() async {
    if (_loop != null) throw StateError('Observer already started.');
    _loop = _run();
    _loop!.ignore();
    await _baseline.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw TimeoutException(
        'Persistent observer never received the published baseline body.',
      ),
    );
  }

  void arm() {
    if (!_baseline.isCompleted) {
      throw StateError('Cannot arm observer before its baseline succeeds.');
    }
    _attempts = 0;
    _responses = 0;
    _errors = 0;
    _staleResponses = 0;
    _armed = true;
  }

  Future<void> waitForCompletedArmedAttempts(
    int minimum, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_responses + _errors < minimum &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_responses + _errors < minimum) {
      throw StateError('Observer did not complete an armed probe before up().');
    }
  }

  Future<_ProbeReport> stop() {
    return _stopFuture ??= _stop();
  }

  Future<_ProbeReport> _stop() async {
    _stopping = true;
    await _loop;
    final status = await tsnet.status();
    return _ProbeReport(
      nodeState: status.state,
      attempts: _attempts,
      responses: _responses,
      errors: _errors,
      staleResponses: _staleResponses,
    );
  }

  Future<void> _run() async {
    while (!_stopping) {
      final count = _armed;
      if (count) _attempts++;
      try {
        final response = await _probe();
        if (!_baseline.isCompleted && response.contains(_publishedBody)) {
          _baseline.complete();
        }
        if (count) {
          _responses++;
          if (response.contains(_replacementBody)) _staleResponses++;
        }
      } catch (_) {
        if (count) _errors++;
      }
      if (!_stopping) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  Future<String> _probe() async {
    TailscaleConnection? connection;
    try {
      connection = await tsnet.tcp.dial(
        targetIpv4,
        tailnetPort,
        timeout: const Duration(milliseconds: 500),
      );
      final nonce = _nonce++;
      final separator = path.contains('?') ? '&' : '?';
      final request =
          'GET $path${separator}probe=$nonce HTTP/1.1\r\n'
          'Host: $hostHeader:$tailnetPort\r\n'
          'Connection: close\r\n'
          'Content-Length: 0\r\n'
          'Cache-Control: no-store\r\n\r\n';
      await connection.output
          .write(utf8.encode(request))
          .timeout(const Duration(seconds: 1));

      final response = BytesBuilder(copy: false);
      await for (final chunk in connection.input.timeout(
        const Duration(seconds: 1),
        onTimeout: (sink) => sink.close(),
      )) {
        response.add(chunk);
        if (response.length >= 64 * 1024) break;
      }
      return utf8.decode(response.takeBytes(), allowMalformed: true);
    } finally {
      await connection?.abort();
    }
  }
}

final class _ProbeReport {
  const _ProbeReport({
    required this.nodeState,
    required this.attempts,
    required this.responses,
    required this.errors,
    required this.staleResponses,
  });

  final NodeState nodeState;
  final int attempts;
  final int responses;
  final int errors;
  final int staleResponses;

  Map<String, Object?> toJson() => <String, Object?>{
    'nodeState': nodeState.name,
    'attempts': attempts,
    'responses': responses,
    'errors': errors,
    'staleResponses': staleResponses,
  };
}

final class _HelperProcess {
  _HelperProcess(this.process, this.label) {
    _stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          _stdout.add(line);
          _lines.add(line);
          stdout.writeln('[crash $label] $line');
        });
    _stderrDone = process.stderr.transform(utf8.decoder).forEach((chunk) {
      _stderr.write(chunk);
      stderr.write('[crash $label stderr] $chunk');
    });
    exitCode = process.exitCode.then((code) async {
      await Future.wait([_stdoutDone, _stderrDone]);
      _exited = true;
      return code;
    });
  }

  final Process process;
  final String label;
  final _lines = StreamController<String>.broadcast();
  final _stdout = <String>[];
  final _stderr = StringBuffer();
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;
  late final Future<int> exitCode;
  var _exited = false;

  Future<Map<String, Object?>> waitForJson(
    String prefix, {
    Duration timeout = const Duration(seconds: 150),
  }) async {
    final marker = '$prefix ';
    String? findExisting() {
      for (final line in _stdout.reversed) {
        if (line.startsWith(marker)) return line;
      }
      return null;
    }

    final existing = findExisting();
    final lineFuture = existing == null
        ? _lines.stream.firstWhere((line) => line.startsWith(marker))
        : Future<String>.value(existing);
    final exited = exitCode.then<String>((code) {
      final finalLine = findExisting();
      if (finalLine != null) return finalLine;
      throw StateError(
        '$label helper exited $code before $prefix; '
        'stderr=${_stderr.toString().trim()}',
      );
    });
    final line = await Future.any(<Future<String>>[
      lineFuture,
      exited,
    ]).timeout(timeout);
    final decoded = jsonDecode(line.substring(marker.length));
    if (decoded is! Map<String, Object?>) {
      throw StateError('$label returned malformed $prefix JSON: $line');
    }
    return decoded;
  }

  Future<void> send(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
  }

  Future<void> crash() async {
    if (_exited) {
      throw StateError('$label exited before the requested SIGKILL.');
    }
    if (!process.kill(ProcessSignal.sigkill)) {
      throw StateError('Could not SIGKILL $label helper.');
    }
    final code = await exitCode.timeout(const Duration(seconds: 15));
    if (code == 0) {
      throw StateError('$label reported a clean exit after SIGKILL.');
    }
  }

  Future<void> expectExit(int expected) async {
    final code = await exitCode.timeout(const Duration(seconds: 30));
    if (code != expected) {
      throw StateError(
        '$label helper exited $code, expected $expected; '
        'stderr=${_stderr.toString().trim()}',
      );
    }
  }

  Future<void> terminate() async {
    if (!_exited) {
      process.kill(ProcessSignal.sigkill);
      try {
        await exitCode.timeout(const Duration(seconds: 15));
      } catch (_) {}
    }
  }
}
