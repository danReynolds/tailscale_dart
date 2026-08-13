// ignore_for_file: cancel_subscriptions

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tailscale_profile_harness/tailscale_profile_harness.dart';

import 'result_report.dart';

const _knownTargets = ['macos', 'ios', 'android', 'linux'];
const _defaultTargets = ['macos', 'ios', 'android'];
const _resultPrefix = 'DUNE_SMOKE_RESULT ';
const _runnerTokenHeader = 'x-dune-smoke-token';

Future<void> main(List<String> args) async {
  final config = _Config.parse(args);
  if (config.help) {
    _printUsage();
    return;
  }

  final runner = _SmokeMatrixRunner(config);
  final ok = await runner.run();
  if (!ok) exitCode = 1;
}

final class _SmokeMatrixRunner {
  _SmokeMatrixRunner(this.config);

  final _Config config;
  late final String root = _repoRoot();
  late final String composeFile = '$root/test/e2e/docker-compose.yml';
  late final String demoCoreDir = '$root/packages/demo_core';
  late final String smokeAppDir = '$root/packages/demo_smoke_flutter';
  late final int _runStartMillis = DateTime.now().millisecondsSinceEpoch;
  late final String _runnerToken = _loadOrCreateRunnerToken();
  Process? _launchedAndroidEmulator;
  HttpServer? _runnerServer;
  ServerSocket? _lanProfileServer;
  StreamSubscription<Socket>? _lanProfileConnections;
  String? _currentAuthKey;
  String? _currentTargetIp;
  final Map<String, Completer<Map<String, Object?>>> _resultCompleters = {};

  Future<bool> run() async {
    final stateRoot = Directory.systemTemp.createTempSync('dune_smoke_matrix_');
    _ManagedPeer? peer;
    var headscaleStarted = false;
    final preBuildFutures = <String, Future<String>>{};
    try {
      await _preparePackageDependencies();
      // Pre-builds run in parallel with peer setup since auth key + target IP
      // are no longer compile-time constants. The futures resolve to the path
      // of the built artifact, used by `flutter run --use-application-binary`.
      if (config.preBuild) {
        for (final target in config.targets) {
          if (_buildArgsFor(target) == null) continue;
          preBuildFutures[target] = _preBuildTarget(target);
        }
      }
      await _startRunnerServer();
      if (config.profileSamples > 0) await _startLanProfileServer();
      await _startHeadscale();
      headscaleStarted = true;
      _currentAuthKey = await _createAuthKey();
      peer = await _ManagedPeer.spawn(
        dart: config.dart,
        packageRoot: demoCoreDir,
        stateDir: '${stateRoot.path}/peer',
        authKey: _currentAuthKey!,
        controlUrl: _hostControlUrl,
      );
      final peerReady = await peer.ready.timeout(config.timeout);
      _currentTargetIp = peerReady.ip;
      _log('headless peer ready at ${peerReady.ip}');

      var devices = await _flutterDevices();
      if (config.targets.contains('android') &&
          _deviceIdFor('android', devices) == null &&
          config.androidAvd != null) {
        await _launchAndroidAvd(config.androidAvd!);
        devices = await _waitForFlutterDevice('android');
      }
      if (config.targets.contains('ios') &&
          !config.deviceOverrides.containsKey('ios') &&
          !_hasIosSimulator(devices)) {
        await _launchIosSimulator(config.iosSimulator);
        devices = await _waitForFlutterDevice('ios', requireEmulator: true);
      }

      final runs = config.targets
          .map((target) {
            final deviceId = _deviceIdFor(target, devices);
            return _TargetLaunch(
              target,
              deviceId,
              _deviceMetadata(target, deviceId, devices),
            );
          })
          .toList(growable: false);
      final results = await _runFlutterTargets(
        runs: runs,
        preBuildFutures: preBuildFutures,
      );

      final failed = results.where((result) => !result.ok).toList();
      final skipped = results.where((result) => result.skipped).toList();
      _log('');
      _log('Smoke matrix summary:');
      for (final result in results) {
        final correctnessOk = result.result?['ok'] == true;
        final state = result.skipped
            ? 'SKIP'
            : correctnessOk && result.ok
            ? 'PASS'
            : correctnessOk
            ? 'PROFILE INVALID'
            : 'FAIL';
        _log('  ${result.target}: $state ${result.message}');
      }
      _log('');
      _log('Capability matrix:');
      stdout.writeln(renderSmokeCapabilityMatrix(_reportRuns(results)));
      await _writeResultReport(results);

      if (config.strict && skipped.isNotEmpty) return false;
      return failed.isEmpty;
    } finally {
      // Detach `compose down -v` so the runner exits as soon as the summary is
      // reported. Detached docker continues teardown in the background.
      if (headscaleStarted && !config.keepHeadscale) {
        _log('detaching docker compose down -v in background');
        try {
          await Process.start(
            config.docker,
            ['compose', '-f', composeFile, 'down', '-v'],
            environment: {'HEADSCALE_PORT': config.headscalePort},
            mode: ProcessStartMode.detached,
          );
        } catch (error) {
          stderr.writeln('failed to detach docker compose down -v: $error');
        }
      }
      // The peer owns a runtime rooted below stateRoot. Stop it before deleting
      // that directory so native teardown can validate and release its state
      // lease instead of racing a recursive delete.
      if (peer != null) await peer.stop();
      await Future.wait(<Future<void>>[
        Future(() {
          try {
            stateRoot.deleteSync(recursive: true);
          } catch (_) {}
        }),
        _stopLaunchedAndroidEmulator(),
        _stopLanProfileServer(),
        _stopRunnerServer(),
        // Drain any still-pending pre-builds so the runner doesn't leave
        // stray flutter build subprocesses behind. Errors are absorbed.
        for (final future in preBuildFutures.values)
          future.then((_) {}, onError: (Object _) {}),
      ]);
    }
  }

  List<Map<String, Object?>> _reportRuns(List<_TargetRun> results) => [
    for (final result in results)
      <String, Object?>{
        'target': result.target,
        'ok': result.result?['ok'] == true,
        'requestedOk': result.ok,
        'skipped': result.skipped,
        if (result.result != null) 'result': result.result,
        if (result.device != null) 'device': result.device,
      },
  ];

  Future<void> _writeResultReport(List<_TargetRun> results) async {
    if (config.outputPath == null && config.profileSamples == 0) return;
    final requestedPath = config.outputPath;
    final defaultName =
        'tailscale-device-profile-'
        '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json';
    final rawPath = requestedPath == null
        ? '${Directory.systemTemp.path}/$defaultName'
        : File(requestedPath).absolute.path;
    final jsonPath = rawPath.endsWith('.json') ? rawPath : '$rawPath.json';
    final jsonFile = File(jsonPath);
    final artifact = buildSmokeRunArtifact(
      runs: _reportRuns(results),
      source: await _sourceMetadata(),
      environment: await _environmentMetadata(),
      profileSamples: config.profileSamples,
      profileContext: config.profileContext,
    );
    jsonFile.parent.createSync(recursive: true);
    jsonFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(artifact),
      flush: true,
    );
    final markdownFile = File(
      '${jsonPath.substring(0, jsonPath.length - '.json'.length)}.md',
    );
    markdownFile.writeAsStringSync(
      renderSmokeRunMarkdown(artifact),
      flush: true,
    );
    _log('JSON result: ${jsonFile.path}');
    _log('Markdown summary: ${markdownFile.path}');
  }

  Future<Map<String, Object?>> _sourceMetadata() async {
    final versionMatch = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('$root/pubspec.yaml').readAsStringSync());
    final head = await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root);
    final status = await Process.run('git', [
      'status',
      '--porcelain',
    ], workingDirectory: root);
    return <String, Object?>{
      'package': 'tailscale',
      'version': versionMatch?.group(1) ?? 'unknown',
      'commit': head.exitCode == 0 ? (head.stdout as String).trim() : 'unknown',
      'dirty':
          status.exitCode != 0 || (status.stdout as String).trim().isNotEmpty,
    };
  }

  Future<Map<String, Object?>> _environmentMetadata() async {
    String flutterVersion = 'unknown';
    String dartVersion = Platform.version.split(' ').first;
    final result = await Process.run(config.flutter, [
      '--version',
      '--machine',
    ]);
    if (result.exitCode == 0) {
      try {
        final data =
            jsonDecode(result.stdout as String) as Map<String, Object?>;
        flutterVersion = data['flutterVersion'] as String? ?? flutterVersion;
        dartVersion = data['dartSdkVersion'] as String? ?? dartVersion;
      } catch (_) {}
    }
    return <String, Object?>{
      'flutter': flutterVersion,
      'dart': dartVersion,
      'hostOperatingSystem': Platform.operatingSystem,
      'hostOperatingSystemVersion': Platform.operatingSystemVersion,
      'flutterRunMode': config.profileSamples > 0
          ? config.profileRunMode
          : 'smoke-default',
      'flutterLaunchMode': config.profileDetached ? 'detached' : 'attached',
    };
  }

  Future<void> _preparePackageDependencies() async {
    _log('preparing demo package dependencies');
    await Future.wait(<Future<ProcessResult>>[
      _run(config.dart, ['pub', 'get'], workingDirectory: demoCoreDir),
      _run(config.flutter, ['pub', 'get'], workingDirectory: smokeAppDir),
    ]);
  }

  List<String>? _buildArgsFor(String target) {
    final runMode = _runModeFor(target);
    switch (target) {
      case 'macos':
        return ['build', 'macos', '--$runMode'];
      case 'ios':
        // Pre-build for the iOS simulator. If the user pinned an iOS device
        // override, fall back to flutter run's inline build (skip pre-build).
        if (config.deviceOverrides.containsKey('ios')) return null;
        return ['build', 'ios', '--simulator', '--debug', '--no-codesign'];
      case 'android':
        return ['build', 'apk', '--$runMode'];
      default:
        return null;
    }
  }

  String _binaryPathFor(String target) {
    final runMode = _runModeFor(target);
    switch (target) {
      case 'macos':
        final configuration = runMode == 'profile' ? 'Profile' : 'Debug';
        return '$smokeAppDir/build/macos/Build/Products/$configuration/'
            'dune_smoke_flutter.app';
      case 'ios':
        return '$smokeAppDir/build/ios/iphonesimulator/Runner.app';
      case 'android':
        return '$smokeAppDir/build/app/outputs/flutter-apk/app-$runMode.apk';
      default:
        throw StateError('no binary path for $target');
    }
  }

  String _runModeFor(String target) => config.profileSamples > 0
      ? config.profileRunMode
      : target == 'android'
      ? config.androidRunMode
      : 'debug';

  Future<String> _preBuildTarget(String target) async {
    final args = _buildArgsFor(target);
    if (args == null) {
      throw StateError('pre-build not supported for $target');
    }
    _log('pre-building $target ($args)');
    final buildArgs = [...args, ..._smokeAppDartDefines(target)];
    final sw = Stopwatch()..start();
    final process = await Process.start(
      config.flutter,
      buildArgs,
      workingDirectory: smokeAppDir,
    );
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => stdout.writeln(_redactSecrets('[$target/build] $line')),
        );
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => stderr.writeln(_redactSecrets('[$target/build] $line')),
        );
    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (exitCode != 0) {
      throw StateError('flutter build $target exited with $exitCode');
    }
    final path = _binaryPathFor(target);
    _log(
      'pre-built $target in ${sw.elapsed.inSeconds}s '
      '(${path.split('/').last})',
    );
    return path;
  }

  Future<void> _startRunnerServer() async {
    _runnerServer = await HttpServer.bind(
      config.runnerBindAddress,
      config.runnerPort,
    );
    _log(
      'runner HTTP server listening on '
      '${config.runnerBindAddress}:${config.runnerPort}',
    );
    unawaited(_serveRunnerRequests());
  }

  Future<void> _stopRunnerServer() async {
    final server = _runnerServer;
    _runnerServer = null;
    if (server == null) return;
    await server.close(force: true);
  }

  Future<void> _startLanProfileServer() async {
    final server = await ServerSocket.bind(config.runnerBindAddress, 0);
    _lanProfileServer = server;
    _lanProfileConnections = server.listen((socket) {
      unawaited(
        serveSpeedTestConnection(
          SpeedTestConnection.bufferedSink(
            input: socket,
            add: socket.add,
            flush: socket.flush,
            close: () async => socket.destroy(),
          ),
        ).then<void>(
          (_) {},
          onError: (Object error) {
            stderr.writeln('LAN profile connection failed: $error');
          },
        ),
      );
    });
    _log(
      'ordinary-LAN profile server listening on '
      '${config.runnerBindAddress}:${server.port}',
    );
  }

  Future<void> _stopLanProfileServer() async {
    final subscription = _lanProfileConnections;
    _lanProfileConnections = null;
    if (subscription != null) await subscription.cancel();
    final server = _lanProfileServer;
    _lanProfileServer = null;
    if (server != null) await server.close();
  }

  Future<void> _serveRunnerRequests() async {
    final server = _runnerServer;
    if (server == null) return;
    try {
      await for (final request in server) {
        try {
          await _handleRunnerRequest(request);
        } catch (error) {
          stderr.writeln('runner HTTP handler error: $error');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Server closed during shutdown.
    }
  }

  Future<void> _handleRunnerRequest(HttpRequest request) async {
    final session = request.uri.queryParameters['session'] ?? 'default';
    final path = request.uri.path;
    if (!_isRunnerRequestAuthorized(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/config') {
      final lanServer = _lanProfileServer;
      final body = <String, Object?>{
        'authKey': _currentAuthKey ?? '',
        'controlUrl': _controlUrlFor(session),
        'targetIp': _currentTargetIp ?? '',
        'hostname': 'dune-smoke-$session',
        'stateSuffix': '$session-$_runStartMillis',
        'profileSamples': config.profileSamples,
        'profileContext': config.profileContext,
        if (lanServer != null) ...{
          'lanProfileHost': _lanProfileHost(session, request),
          'lanProfilePort': lanServer.port,
        },
      };
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && path == '/result') {
      final raw = await utf8.decoder.bind(request).join();
      Map<String, Object?>? data;
      try {
        data = jsonDecode(raw) as Map<String, Object?>;
      } catch (_) {}
      final completer = _resultCompleters[session];
      if (data != null &&
          _isValidSmokeResult(data) &&
          completer != null &&
          !completer.isCompleted) {
        completer.complete(data);
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  String _lanProfileHost(String target, HttpRequest request) {
    final specific =
        Platform.environment['DUNE_SMOKE_LAN_HOST_${target.toUpperCase()}'];
    if (specific != null && specific.isNotEmpty) return specific;
    final shared = Platform.environment['DUNE_SMOKE_LAN_HOST'];
    if (shared != null && shared.isNotEmpty) return shared;
    final requestedHost = request.requestedUri.host;
    if (requestedHost.isNotEmpty && requestedHost != '0.0.0.0') {
      return requestedHost;
    }
    return Uri.parse(_runnerUrlFor(target)).host;
  }

  bool _isRunnerRequestAuthorized(HttpRequest request) {
    // Header-only: the runner logs every flutter run line verbatim, and a
    // token in the query string would land in those logs (and any pasted
    // bug report). The smoke app's runner_client uses the header path.
    final token = request.headers.value(_runnerTokenHeader);
    if (token == null || token.length != _runnerToken.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= token.codeUnitAt(i) ^ _runnerToken.codeUnitAt(i);
    }
    return diff == 0;
  }

  bool _isValidSmokeResult(Map<String, Object?> data) {
    return data['ok'] is bool &&
        data['startedAt'] is String &&
        data['finishedAt'] is String &&
        data['hostname'] is String &&
        data['platform'] is String &&
        data['targetIp'] is String;
  }

  String _runnerUrlFor(String target) {
    final specific =
        Platform.environment['DUNE_SMOKE_RUNNER_URL_${target.toUpperCase()}'];
    if (specific != null && specific.isNotEmpty) return specific;
    final shared = Platform.environment['DUNE_SMOKE_RUNNER_URL'];
    if (shared != null && shared.isNotEmpty) return shared;
    if (target == 'android') return 'http://10.0.2.2:${config.runnerPort}';
    return 'http://localhost:${config.runnerPort}';
  }

  String _loadOrCreateRunnerToken() {
    final fromEnv = Platform.environment['DUNE_SMOKE_RUNNER_TOKEN'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

    final file = File('$root/.dart_tool/dune_smoke_runner_token');
    try {
      if (file.existsSync()) {
        final existing = file.readAsStringSync().trim();
        if (existing.isNotEmpty) return existing;
      }
      file.parent.createSync(recursive: true);
      final token = _newRunnerToken();
      file.writeAsStringSync('$token\n', flush: true);
      _setOwnerOnlyFileMode(file);
      return token;
    } catch (_) {
      return _newRunnerToken();
    }
  }

  String _newRunnerToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String get _hostControlUrl => 'http://localhost:${config.headscalePort}';

  Future<void> _startHeadscale() async {
    _log('starting Headscale on $_hostControlUrl');
    await _run(
      config.docker,
      ['compose', '-f', composeFile, 'up', '-d', '--wait'],
      environment: {'HEADSCALE_PORT': config.headscalePort},
    );

    final uri = Uri.parse('$_hostControlUrl/health');
    final client = HttpClient();
    try {
      for (var i = 0; i < 60; i++) {
        try {
          final request = await client.getUrl(uri);
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode >= 200 && response.statusCode < 300) return;
        } catch (_) {
          // Keep polling until the control server accepts connections.
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      throw StateError('Headscale did not become healthy at $uri');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _createAuthKey() async {
    await _run(
      config.docker,
      [
        'compose',
        '-f',
        composeFile,
        'exec',
        '-T',
        'headscale',
        'headscale',
        'users',
        'create',
        'dune-smoke',
      ],
      environment: {'HEADSCALE_PORT': config.headscalePort},
      allowFailure: true,
    );
    final result = await _run(
      config.docker,
      [
        'compose',
        '-f',
        composeFile,
        'exec',
        '-T',
        'headscale',
        'headscale',
        'preauthkeys',
        'create',
        '--user',
        'dune-smoke',
        '--reusable',
        '--ephemeral',
        '--expiration',
        '30m',
      ],
      environment: {'HEADSCALE_PORT': config.headscalePort},
    );
    final stdoutText = result.stdout as String;
    final tskeyMatches = RegExp(
      r'tskey-auth-[A-Za-z0-9_-]+',
    ).allMatches(stdoutText).toList(growable: false);
    if (tskeyMatches.isNotEmpty) return tskeyMatches.last.group(0)!;

    final rawKeys = stdoutText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => RegExp(r'^[A-Fa-f0-9]{32,}$').hasMatch(line))
        .toList(growable: false);
    if (rawKeys.isNotEmpty) return rawKeys.last;

    throw StateError('could not parse Headscale auth key');
  }

  Future<List<_FlutterDevice>> _flutterDevices() async {
    final result = await _run(config.flutter, [
      'devices',
      '--machine',
    ], allowFailure: true);
    if (result.exitCode != 0) return const [];
    try {
      final decoded = jsonDecode(result.stdout as String) as List<dynamic>;
      return decoded
          .cast<Map<String, Object?>>()
          .map(_FlutterDevice.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<_FlutterDevice>> _waitForFlutterDevice(
    String target, {
    bool requireEmulator = false,
  }) async {
    for (var i = 0; i < 90; i++) {
      final devices = await _flutterDevices();
      if (_deviceIdFor(target, devices) != null) {
        if (!requireEmulator) return devices;
        // The runner may have just launched an emulator/simulator. Don't
        // settle for a physical device match — wait until an emulator
        // appears, otherwise an attached wireless iPhone gets picked even
        // when we explicitly asked for the simulator.
        if (devices.any(
          (device) => device.emulator && _matchesTarget(device, target),
        )) {
          return devices;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return _flutterDevices();
  }

  bool _matchesTarget(_FlutterDevice device, String target) {
    final id = device.id.toLowerCase();
    final platform = device.targetPlatform.toLowerCase();
    return switch (target) {
      'macos' => id == 'macos' || platform.contains('darwin'),
      'linux' => id == 'linux' || platform.contains('linux'),
      'ios' => platform.contains('ios') || device.platformType == 'ios',
      'android' =>
        platform.contains('android') || device.platformType == 'android',
      _ => false,
    };
  }

  String? _deviceIdFor(String target, List<_FlutterDevice> devices) {
    final override = config.deviceOverrides[target];
    if (override != null && override.isNotEmpty) return override;

    bool matches(_FlutterDevice device) {
      final id = device.id.toLowerCase();
      final platform = device.targetPlatform.toLowerCase();
      return switch (target) {
        'macos' => id == 'macos' || platform.contains('darwin'),
        'linux' => id == 'linux' || platform.contains('linux'),
        'ios' => platform.contains('ios') || device.platformType == 'ios',
        'android' =>
          platform.contains('android') || device.platformType == 'android',
        _ => false,
      };
    }

    final matchesForTarget = devices.where(matches).toList();
    if (matchesForTarget.isEmpty) return null;
    // Prefer emulators/simulators over physical devices for automated runs.
    // Physical devices (especially over wireless) can sleep, miss trust
    // prompts, or hang on cold install — none of which an automated matrix
    // can recover from.
    matchesForTarget.sort(
      (a, b) => (b.emulator ? 1 : 0) - (a.emulator ? 1 : 0),
    );
    return matchesForTarget.first.id;
  }

  Map<String, Object?>? _deviceMetadata(
    String target,
    String? deviceId,
    List<_FlutterDevice> devices,
  ) {
    if (deviceId == null) return null;
    for (final device in devices) {
      if (device.id == deviceId) {
        return <String, Object?>{
          ...device.reportMetadata,
          'deviceClass': target == 'ios' || target == 'android'
              ? device.emulator
                    ? 'emulator'
                    : 'physical'
              : 'host',
        };
      }
    }
    return null;
  }

  Future<_TargetRun> _runFlutterTarget({
    required String target,
    required String deviceId,
    required Map<String, Object?>? device,
    Future<String>? preBuildFuture,
  }) async {
    if (target == 'android') {
      await _waitForAndroidReady(deviceId);
    }
    String? binaryPath;
    if (preBuildFuture != null) {
      try {
        final candidate = await preBuildFuture;
        if (FileSystemEntity.typeSync(candidate) ==
            FileSystemEntityType.notFound) {
          _log(
            '$target pre-built artifact missing at $candidate; '
            'falling back to inline build',
          );
        } else {
          binaryPath = candidate;
          _log('$target using pre-built binary at $candidate');
        }
      } catch (error) {
        _log('$target pre-build failed: $error; falling back to inline build');
      }
    }
    final runnerUrl = _runnerUrlFor(target);
    if (target == 'android') {
      // Start the SIGSYS receipt from a clean buffer so the post-run scan can
      // only see this run's crashes.
      await _run(config.adb, [
        '-s',
        deviceId,
        'logcat',
        '-c',
      ], allowFailure: true);
    }
    _log('running $target smoke on Flutter device $deviceId');
    final runMode = _runModeFor(target);
    final process = await Process.start(config.flutter, [
      'run',
      '-d',
      deviceId,
      '--$runMode',
      if (config.profileDetached) ...[
        '--no-resident',
        '--no-enable-dart-profiling',
        '--no-dds',
        '--no-devtools',
        if (target == 'ios') '--no-publish-port',
      ],
      if (binaryPath != null) ...['--use-application-binary', binaryPath],
      ..._smokeAppDartDefines(target, runnerUrl: runnerUrl),
    ], workingDirectory: smokeAppDir);

    final result = Completer<_TargetRun>();
    final httpResult = Completer<Map<String, Object?>>();
    _resultCompleters[target] = httpResult;
    unawaited(
      httpResult.future.then((data) {
        if (result.isCompleted) return;
        final ok = _requestedResultOk(data);
        final duration = data['durationMs'];
        result.complete(
          _TargetRun(
            target: target,
            ok: ok,
            skipped: false,
            message: _resultMessage(data, ok: ok, duration: duration),
            result: data,
            device: device,
          ),
        );
      }),
    );

    void handleLine(String stream, String line) {
      stdout.writeln(_redactSecrets('[$target/$stream] $line'));
      final resultIndex = line.indexOf(_resultPrefix);
      if (resultIndex < 0 || result.isCompleted) return;
      // Stdout result is a fallback path if /result POST never lands.
      final jsonText = line.substring(resultIndex + _resultPrefix.length);
      try {
        final decoded = jsonDecode(jsonText) as Map<String, Object?>;
        final ok = _requestedResultOk(decoded);
        final duration = decoded['durationMs'];
        result.complete(
          _TargetRun(
            target: target,
            ok: ok,
            skipped: false,
            message: _resultMessage(decoded, ok: ok, duration: duration),
            result: decoded,
            device: device,
          ),
        );
      } catch (error) {
        // Don't complete the result on stdout parse errors. Lines from
        // `flutter run` can be truncated mid-flush when the device
        // disconnects (e.g., "Lost connection to device" cuts the
        // DUNE_SMOKE_RESULT line). The /result POST is the primary
        // signal; let it land or let the outer timeout catch a real hang.
        stderr.writeln(
          '[$target/$stream] result line parse failed (truncated?): $error',
        );
      }
    }

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => handleLine('out', line));
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => handleLine('err', line));

    unawaited(
      process.exitCode.then((code) {
        if (!result.isCompleted && (!config.profileDetached || code != 0)) {
          result.complete(
            _TargetRun(
              target: target,
              ok: false,
              skipped: false,
              message: 'flutter run exited before smoke result: $code',
              device: device,
            ),
          );
        }
      }),
    );

    try {
      var run = await result.future.timeout(config.timeout);
      if (target == 'android') {
        run = await _applyAndroidSigsysCheck(run, deviceId);
      }
      return run;
    } on TimeoutException {
      return _TargetRun(
        target: target,
        ok: false,
        skipped: false,
        message: 'timed out after ${config.timeout.inSeconds}s',
        device: device,
      );
    } finally {
      _resultCompleters.remove(target);
      process.kill(ProcessSignal.sigint);
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }
  }

  Future<List<_TargetRun>> _runFlutterTargets({
    required List<_TargetLaunch> runs,
    required Map<String, Future<String>> preBuildFutures,
  }) async {
    if (config.jobs <= 1) {
      final results = <_TargetRun>[];
      for (final run in runs) {
        results.add(await _runOrSkipTarget(run, preBuildFutures));
      }
      return results;
    }

    final results = List<_TargetRun?>.filled(runs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next;
        if (index >= runs.length) return;
        next++;
        results[index] = await _runOrSkipTarget(runs[index], preBuildFutures);
      }
    }

    final workerCount = config.jobs < runs.length ? config.jobs : runs.length;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    return results.cast<_TargetRun>();
  }

  bool _requestedResultOk(Map<String, Object?> result) {
    if (result['ok'] != true) return false;
    if (config.profileSamples == 0) return true;
    final profile = result['profile'];
    return profile is Map<String, Object?> && profile['status'] == 'complete';
  }

  String _resultMessage(
    Map<String, Object?> result, {
    required bool ok,
    required Object? duration,
  }) {
    if (ok) return 'completed in ${duration ?? '?'}ms';
    if (result['ok'] == true && result['profile'] is Map<String, Object?>) {
      final profile = result['profile']! as Map<String, Object?>;
      final status = profile['status'] ?? 'invalid';
      final error = profile['error'];
      return error is String && error.isNotEmpty
          ? 'profile $status: $error'
          : 'profile $status';
    }
    return result['error'] as String? ?? 'probe failed';
  }

  Future<_TargetRun> _runOrSkipTarget(
    _TargetLaunch run,
    Map<String, Future<String>> preBuildFutures,
  ) async {
    final deviceId = run.deviceId;
    if (deviceId == null) {
      final skipped = _TargetRun.skipped(
        run.target,
        'no Flutter device found',
        device: run.device,
      );
      _log('${run.target.toUpperCase()} SKIP ${skipped.message}');
      return skipped;
    }
    try {
      return await _runFlutterTarget(
        target: run.target,
        deviceId: deviceId,
        device: run.device,
        preBuildFuture: preBuildFutures[run.target],
      );
    } catch (error) {
      return _TargetRun(
        target: run.target,
        ok: false,
        skipped: false,
        message: error.toString(),
        device: run.device,
      );
    }
  }

  String _controlUrlFor(String target) {
    final specific =
        Platform.environment['DUNE_SMOKE_CONTROL_URL_${target.toUpperCase()}'];
    if (specific != null && specific.isNotEmpty) return specific;
    final shared = Platform.environment['DUNE_SMOKE_CONTROL_URL'];
    if (shared != null && shared.isNotEmpty) return shared;
    if (target == 'android') return 'http://10.0.2.2:${config.headscalePort}';
    return _hostControlUrl;
  }

  List<String> _smokeAppDartDefines(String target, {String? runnerUrl}) {
    return [
      '--dart-define=DUNE_SMOKE_RUNNER_URL=${runnerUrl ?? _runnerUrlFor(target)}',
      '--dart-define=DUNE_SMOKE_SESSION=$target',
      '--dart-define=DUNE_SMOKE_RUNNER_TOKEN=$_runnerToken',
    ];
  }

  Future<void> _launchAndroidAvd(String avd) async {
    final emulator = _androidEmulatorExecutable();
    _log('launching Android emulator $avd with $emulator');
    final process = await Process.start(emulator, [
      '-avd',
      avd,
      '-no-snapshot',
      '-no-audio',
    ]);
    _launchedAndroidEmulator = process;

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) =>
              stdout.writeln(_redactSecrets('[android-emulator/out] $line')),
        );
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) =>
              stderr.writeln(_redactSecrets('[android-emulator/err] $line')),
        );
    unawaited(
      process.exitCode.then((code) async {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        if (_launchedAndroidEmulator == process) {
          _launchedAndroidEmulator = null;
        }
        if (code != 0) {
          stderr.writeln('Android emulator exited with code $code');
        }
      }),
    );
  }

  Future<void> _stopLaunchedAndroidEmulator() async {
    final process = _launchedAndroidEmulator;
    if (process == null || config.keepAndroidEmulator) return;
    await _run(config.adb, ['emu', 'kill'], allowFailure: true);
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    _launchedAndroidEmulator = null;
  }

  bool _hasIosSimulator(List<_FlutterDevice> devices) {
    return devices.any((device) {
      if (!device.emulator) return false;
      final platform = device.targetPlatform.toLowerCase();
      return platform.contains('ios') || device.platformType == 'ios';
    });
  }

  Future<void> _launchIosSimulator(String simulatorId) async {
    _log('launching iOS Simulator $simulatorId');
    final result = await Process.run(config.flutter, [
      'emulators',
      '--launch',
      simulatorId,
    ]);
    if (result.exitCode != 0) {
      final err = (result.stderr as String? ?? '').trim();
      throw StateError('failed to launch iOS Simulator $simulatorId: $err');
    }
  }

  /// The Android runtime-receipt scan: the smoke (including its restart
  /// cycle) must finish without the app-process seccomp policy killing a
  /// thread. Zygote-spawned app processes carry the real policy — a binary
  /// run from adb shell would not — so probe success plus a clean crash scan
  /// here IS the Server.Start/reconnect/stop receipt. The full dump is saved
  /// beside the system temp directory as the receipt artifact.
  Future<_TargetRun> _applyAndroidSigsysCheck(
    _TargetRun run,
    String deviceId,
  ) async {
    try {
      final dump = await _run(config.adb, [
        '-s',
        deviceId,
        'logcat',
        '-d',
      ], allowFailure: true);
      final text = dump.stdout as String? ?? '';
      final artifact = File(
        '${Directory.systemTemp.path}/dune_smoke_android_logcat_$_runStartMillis.txt',
      );
      artifact.writeAsStringSync(text);
      _log('android logcat receipt saved to ${artifact.path}');
      // Match crash-specific signatures only; benign boot chatter can mention
      // seccomp policy installation without any violation.
      final violations = text
          .split('\n')
          .where(
            (line) => line.contains('SIGSYS') || line.contains('SYS_SECCOMP'),
          )
          .toList(growable: false);
      if (violations.isNotEmpty) {
        _log('android SIGSYS lines:\n${violations.join('\n')}');
        return _TargetRun(
          target: run.target,
          ok: false,
          skipped: false,
          message:
              'seccomp SIGSYS in logcat (${violations.length} lines; '
              'see ${artifact.path})',
          result: run.result,
          device: run.device,
        );
      }
    } catch (error) {
      _log('android logcat scan failed (receipt not collected): $error');
    }
    return run;
  }

  String _androidEmulatorExecutable() {
    final explicit = config.emulator;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final androidHome =
        Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];
    if (androidHome != null && androidHome.isNotEmpty) {
      return '$androidHome/emulator/emulator';
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home/Library/Android/sdk/emulator/emulator';
    }
    return 'emulator';
  }

  Future<void> _waitForAndroidReady(String deviceId) async {
    _log('waiting for Android device $deviceId to finish booting');
    await _run(config.adb, ['-s', deviceId, 'wait-for-device']);
    Object? lastStatus;
    var systemReady = false;
    for (var i = 0; i < 120; i++) {
      try {
        final booted = await _adbShell(deviceId, [
          'getprop',
          'sys.boot_completed',
        ]);
        final packageService = await _adbShell(deviceId, [
          'service',
          'check',
          'package',
        ]);
        final packageManager = await _adbShell(deviceId, [
          'pm',
          'path',
          'android',
        ]);
        if (booted.stdout.trim() == '1' &&
            packageService.stdout.contains('found') &&
            packageManager.exitCode == 0) {
          systemReady = true;
          break;
        }
        lastStatus =
            'boot=${booted.stdout.trim()} '
            'packageService=${packageService.stdout.trim()} '
            'pmExit=${packageManager.exitCode}';
      } catch (error) {
        lastStatus = error;
      }
      if (i % 10 == 0) {
        _log('Android device $deviceId is not ready yet: $lastStatus');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!systemReady) {
      throw TimeoutException(
        'Android device $deviceId did not become ready: $lastStatus',
      );
    }
    await _ensureAndroidInteractive(deviceId);
    _log('Android device $deviceId is ready');
  }

  Future<void> _ensureAndroidInteractive(String deviceId) async {
    await _adbShell(deviceId, ['input', 'keyevent', 'KEYCODE_WAKEUP']);
    await _adbShell(deviceId, ['wm', 'dismiss-keyguard']);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final power = await _adbShell(deviceId, ['dumpsys', 'power']);
    final window = await _adbShell(deviceId, ['dumpsys', 'window']);
    final powerText = power.stdout.toString();
    final windowText = window.stdout.toString();
    final awake = powerText.contains('mWakefulness=Awake');
    final securelyLocked =
        windowText.contains('mDreamingLockscreen=true') ||
        windowText.contains('mShowingLockscreen=true') ||
        windowText.contains('isStatusBarKeyguard=true');
    if (!awake || securelyLocked) {
      throw StateError(
        'Android device $deviceId is asleep or securely locked. '
        'Unlock it and leave the screen awake before rerunning.',
      );
    }
  }

  Future<ProcessResult> _adbShell(String deviceId, List<String> shellArgs) {
    return Process.run(config.adb, [
      '-s',
      deviceId,
      'shell',
      ...shellArgs,
    ]).timeout(const Duration(seconds: 5));
  }
}

final class _ManagedPeer {
  _ManagedPeer._({
    required this.process,
    required this.ready,
    required this.stdoutSub,
    required this.stderrSub,
  });

  final Process process;
  final Future<_ReadyPeer> ready;
  final StreamSubscription<String> stdoutSub;
  final StreamSubscription<String> stderrSub;

  static Future<_ManagedPeer> spawn({
    required String dart,
    required String packageRoot,
    required String stateDir,
    required String authKey,
    required String controlUrl,
  }) async {
    final process = await Process.start(dart, [
      'run',
      'bin/demo_node.dart',
      'serve',
      '--state-dir',
      stateDir,
      '--hostname',
      'dune-smoke-peer',
      '--auth-key',
      authKey,
      '--ephemeral',
      '--control-url',
      controlUrl,
      '--stdin-control',
    ], workingDirectory: packageRoot);

    late _ManagedPeer peer;
    final ready = Completer<_ReadyPeer>();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stdout.writeln(_redactSecrets('[peer/out] $line'));
          final readyIndex = line.indexOf('READY ');
          if (readyIndex >= 0 && !ready.isCompleted) {
            final jsonText = line.substring(readyIndex + 'READY '.length);
            final decoded = jsonDecode(jsonText) as Map<String, Object?>;
            ready.complete(_ReadyPeer(ip: decoded['ip'] as String));
          }
        });
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln(_redactSecrets('[peer/err] $line')));

    peer = _ManagedPeer._(
      process: process,
      ready: ready.future,
      stdoutSub: stdoutSub,
      stderrSub: stderrSub,
    );
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('headless peer exited before READY: $code'),
          );
        }
      }),
    );
    return peer;
  }

  Future<void> stop() async {
    try {
      process.stdin.writeln('STOP');
      await process.stdin.close();
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      // Do not return until the OS has reaped the process. The caller deletes
      // the peer's state directory immediately after this method completes.
      await process.exitCode.timeout(const Duration(seconds: 10));
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }
}

final class _ReadyPeer {
  const _ReadyPeer({required this.ip});

  final String ip;
}

final class _FlutterDevice {
  const _FlutterDevice({
    required this.id,
    required this.targetPlatform,
    required this.platformType,
    required this.emulator,
    required this.sdk,
  });

  final String id;
  final String targetPlatform;
  final String platformType;
  final bool emulator;
  final String sdk;

  Map<String, Object?> get reportMetadata => <String, Object?>{
    'targetPlatform': targetPlatform,
    'platformType': platformType,
    'emulator': emulator,
    if (sdk.isNotEmpty) 'sdk': sdk,
  };

  static _FlutterDevice fromJson(Map<String, Object?> json) => _FlutterDevice(
    id: json['id'] as String? ?? '',
    targetPlatform: json['targetPlatform'] as String? ?? '',
    platformType: json['platformType'] as String? ?? '',
    emulator: json['emulator'] == true,
    sdk: json['sdk'] as String? ?? '',
  );
}

final class _TargetLaunch {
  const _TargetLaunch(this.target, this.deviceId, this.device);

  final String target;
  final String? deviceId;
  final Map<String, Object?>? device;
}

final class _TargetRun {
  const _TargetRun({
    required this.target,
    required this.ok,
    required this.skipped,
    required this.message,
    this.result,
    this.device,
  });

  factory _TargetRun.skipped(
    String target,
    String message, {
    Map<String, Object?>? device,
  }) => _TargetRun(
    target: target,
    ok: true,
    skipped: true,
    message: message,
    device: device,
  );

  final String target;
  final bool ok;
  final bool skipped;
  final String message;
  final Map<String, Object?>? result;
  final Map<String, Object?>? device;
}

final class _Config {
  const _Config({
    required this.targets,
    required this.deviceOverrides,
    required this.timeout,
    required this.headscalePort,
    required this.runnerPort,
    required this.runnerBindAddress,
    required this.dart,
    required this.flutter,
    required this.docker,
    required this.adb,
    required this.emulator,
    required this.androidAvd,
    required this.iosSimulator,
    required this.androidRunMode,
    required this.profileSamples,
    required this.profileContext,
    required this.profileRunMode,
    required this.outputPath,
    required this.jobs,
    required this.keepHeadscale,
    required this.keepAndroidEmulator,
    required this.preBuild,
    required this.strict,
    required this.help,
  });

  final List<String> targets;
  final Map<String, String> deviceOverrides;
  final Duration timeout;
  final String headscalePort;
  final int runnerPort;
  final String runnerBindAddress;
  final String dart;
  final String flutter;
  final String docker;
  final String adb;
  final String? emulator;
  final String? androidAvd;
  final String iosSimulator;
  final String androidRunMode;
  final int profileSamples;
  final String profileContext;
  final String profileRunMode;
  final String? outputPath;
  final int jobs;
  final bool keepHeadscale;
  final bool keepAndroidEmulator;
  final bool preBuild;
  final bool strict;
  final bool help;

  bool get profileDetached => profileSamples > 0;

  static _Config parse(List<String> args) {
    final options = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-h' || arg == '--help') {
        flags.add('help');
        continue;
      }
      if (!arg.startsWith('--')) {
        throw ArgumentError('unexpected argument: $arg');
      }
      final trimmed = arg.substring(2);
      final equals = trimmed.indexOf('=');
      if (equals >= 0) {
        options[trimmed.substring(0, equals)] = trimmed.substring(equals + 1);
        continue;
      }
      final next = i + 1 < args.length ? args[i + 1] : null;
      if (next != null && !next.startsWith('--')) {
        options[trimmed] = next;
        i++;
      } else {
        flags.add(trimmed);
      }
    }

    final requestedTargets =
        options['targets'] ?? Platform.environment['DUNE_SMOKE_TARGETS'];
    final targets = (requestedTargets == null || requestedTargets == 'auto')
        ? _defaultTargets
        : requestedTargets
              .split(',')
              .map((target) => target.trim().toLowerCase())
              .where((target) => target.isNotEmpty)
              .toList(growable: false);
    final invalid = targets.where((target) => !_knownTargets.contains(target));
    if (invalid.isNotEmpty) {
      throw ArgumentError('unknown smoke target(s): ${invalid.join(', ')}');
    }

    final timeoutSeconds =
        int.tryParse(
          options['timeout-seconds'] ??
              Platform.environment['DUNE_SMOKE_TIMEOUT_SECONDS'] ??
              '',
        ) ??
        600;
    final androidRunMode =
        options['android-run-mode'] ??
        Platform.environment['DUNE_SMOKE_ANDROID_RUN_MODE'] ??
        'profile';
    if (androidRunMode != 'debug' && androidRunMode != 'profile') {
      throw ArgumentError(
        'unsupported Android run mode "$androidRunMode"; expected debug or profile',
      );
    }
    final jobs =
        int.tryParse(
          options['jobs'] ?? Platform.environment['DUNE_SMOKE_JOBS'] ?? '',
        ) ??
        1;
    if (jobs < 1) {
      throw ArgumentError('jobs must be >= 1');
    }

    final profileSamples =
        int.tryParse(
          options['profile-samples'] ??
              Platform.environment['DUNE_SMOKE_PROFILE_SAMPLES'] ??
              '',
        ) ??
        0;
    if (profileSamples < 0 || profileSamples > 1000) {
      throw ArgumentError('profile-samples must be in 0..1000');
    }
    final profileContext =
        options['profile-context'] ??
        Platform.environment['DUNE_SMOKE_PROFILE_CONTEXT'] ??
        'primary';
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(profileContext)) {
      throw ArgumentError(
        'profile-context must be a 1-64 character identifier',
      );
    }
    final profileRunMode =
        options['profile-run-mode'] ??
        Platform.environment['DUNE_SMOKE_PROFILE_RUN_MODE'] ??
        'profile';
    if (profileRunMode != 'debug' && profileRunMode != 'profile') {
      throw ArgumentError(
        'unsupported profile run mode "$profileRunMode"; '
        'expected debug or profile',
      );
    }
    final deviceOverrides = <String, String>{};
    for (final target in _knownTargets) {
      final value =
          options['$target-device'] ??
          Platform.environment['DUNE_SMOKE_${target.toUpperCase()}_DEVICE'];
      if (value != null && value.isNotEmpty) {
        deviceOverrides[target] = value;
      }
    }
    if (profileSamples > 0) {
      if (targets.length != 1) {
        throw ArgumentError(
          'device profiling requires exactly one target for comparable results',
        );
      }
      final target = targets.single;
      if ((target == 'ios' || target == 'android') &&
          !deviceOverrides.containsKey(target)) {
        throw ArgumentError(
          'device profiling for $target requires --$target-device so a '
          'simulator or emulator is not selected accidentally',
        );
      }
    }

    final runnerPort =
        int.tryParse(
          options['runner-port'] ??
              Platform.environment['DUNE_SMOKE_RUNNER_PORT'] ??
              '',
        ) ??
        18099;
    if (runnerPort < 1 || runnerPort > 65535) {
      throw ArgumentError('runner-port must be in 1..65535');
    }

    return _Config(
      targets: targets,
      deviceOverrides: deviceOverrides,
      timeout: Duration(seconds: timeoutSeconds),
      headscalePort:
          options['headscale-port'] ??
          Platform.environment['HEADSCALE_PORT'] ??
          '18080',
      runnerPort: runnerPort,
      runnerBindAddress:
          options['runner-bind-address'] ??
          Platform.environment['DUNE_SMOKE_RUNNER_BIND_ADDRESS'] ??
          '127.0.0.1',
      dart: Platform.environment['DART'] ?? 'dart',
      flutter: Platform.environment['FLUTTER'] ?? 'flutter',
      docker: Platform.environment['DOCKER'] ?? 'docker',
      adb: Platform.environment['ADB'] ?? 'adb',
      emulator: options['emulator'] ?? Platform.environment['ANDROID_EMULATOR'],
      androidAvd:
          options['android-avd'] ??
          Platform.environment['DUNE_SMOKE_ANDROID_AVD'],
      iosSimulator:
          options['ios-simulator'] ??
          Platform.environment['DUNE_SMOKE_IOS_SIMULATOR'] ??
          'apple_ios_simulator',
      androidRunMode: androidRunMode,
      profileSamples: profileSamples,
      profileContext: profileContext,
      profileRunMode: profileRunMode,
      outputPath:
          options['output'] ?? Platform.environment['DUNE_SMOKE_OUTPUT'],
      jobs: jobs,
      keepHeadscale:
          flags.contains('keep-headscale') || flags.contains('reuse-headscale'),
      keepAndroidEmulator: flags.contains('keep-android-emulator'),
      preBuild: !flags.contains('no-pre-build'),
      strict: flags.contains('strict'),
      help: flags.contains('help'),
    );
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool allowFailure = false,
}) async {
  _log(_redactSecrets('\$ $executable ${args.join(' ')}'));
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  if (result.stdout case final String out when out.trim().isNotEmpty) {
    stdout.write(_redactSecrets(out));
  }
  if (result.stderr case final String err when err.trim().isNotEmpty) {
    stderr.write(_redactSecrets(err));
  }
  if (!allowFailure && result.exitCode != 0) {
    throw StateError('$executable exited with ${result.exitCode}');
  }
  return result;
}

String _redactSecrets(String text) {
  var redacted = text.replaceAllMapped(
    RegExp(r'tskey-(?:auth|api)-[A-Za-z0-9_-]+'),
    (_) => 'tskey-REDACTED',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(r'(--dart-define=DUNE_SMOKE_RUNNER_TOKEN=)[^\s]+'),
    (match) => '${match.group(1)}REDACTED',
  );
  // Some Headscale versions print raw preauth keys without a tskey-* prefix.
  // These keys are still bearer credentials for the smoke tailnet.
  redacted = redacted.replaceAllMapped(
    RegExp(r'\b[A-Fa-f0-9]{32,}\b'),
    (_) => 'REDACTED_HEX_KEY',
  );
  return redacted;
}

void _setOwnerOnlyFileMode(File file) {
  if (Platform.isWindows) return;
  try {
    final result = Process.runSync('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      stderr.writeln(
        'warning: failed to chmod smoke runner token file: ${result.stderr}',
      );
    }
  } catch (error) {
    stderr.writeln('warning: failed to chmod smoke runner token file: $error');
  }
}

String _repoRoot() {
  var dir = File(Platform.script.toFilePath()).parent;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/go').existsSync() &&
        Directory('${dir.path}/test/e2e').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate repo root');
    }
    dir = parent;
  }
}

final _runStopwatch = Stopwatch()..start();

void _log(String message) {
  final elapsed = (_runStopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
  stdout.writeln('[T+${elapsed}s] $message');
}

void _printUsage() {
  stdout.writeln('''
Usage:
  tool/smoke/run_matrix.sh [options]

Options:
  --targets macos,ios,android,linux   Targets to attempt. Default: macos,ios,android.
  --strict                            Fail if any requested target is missing.
  --timeout-seconds N                 Per-target flutter run timeout. Default: 600.
  --jobs N                            Number of platform targets to run at once. Default: 1.
  --headscale-port N                  Host Headscale port. Default: 18080.
  --runner-port N                     Local HTTP port the runner uses to serve
                                      smoke-app config and accept results.
                                      Default: 18099.
  --runner-bind-address ADDRESS       Address for the runner HTTP server.
                                      Default: 127.0.0.1. Use 0.0.0.0 only
                                      when a physical device must reach it.
  --android-avd NAME                  Launch this Android AVD if no Android device is visible.
  --android-run-mode debug|profile    Android Flutter run mode. Default: profile.
  --profile-samples N                 Collect N repeated network samples after
                                      the functional smoke pass. Uses Flutter
                                      profile mode, detaches Flutter tooling,
                                      and requires one target.
                                      Default: 0 (disabled).
  --profile-run-mode debug|profile    Flutter mode for a profile workload.
                                      Default: profile. Debug is diagnostic,
                                      primarily for iOS Simulator controls.
  --profile-context LABEL             Short environment label stored with the
                                      profile. Default: primary.
  --output PATH                       Write privacy-safe JSON samples plus a
                                      generated Markdown matrix. Profile runs
                                      without this flag write under the system
                                      temporary directory.
  --keep-android-emulator             Leave an emulator launched by this runner alive.
  --ios-simulator ID                  iOS simulator id to launch when iOS is
                                      requested and no iOS simulator is
                                      visible. Default: apple_ios_simulator.
                                      The runner prefers simulators over
                                      physical iOS devices for automation.
  --no-pre-build                      Skip pre-building target binaries in
                                      parallel with peer setup. Default is to
                                      pre-build via `flutter build` and launch
                                      with `flutter run --use-application-binary`,
                                      moving the per-target build off the
                                      critical path.
  --macos-device ID                   Flutter device id override.
  --ios-device ID                     Flutter device id override.
  --android-device ID                 Flutter device id override.
  --linux-device ID                   Flutter device id override.
  --keep-headscale                    Leave Docker Headscale running.
  --reuse-headscale                   Alias for --keep-headscale.

Environment:
  DUNE_SMOKE_TARGETS                  Same as --targets.
  DUNE_SMOKE_JOBS                     Same as --jobs.
  DUNE_SMOKE_ANDROID_AVD              Same as --android-avd.
  DUNE_SMOKE_ANDROID_RUN_MODE         Same as --android-run-mode.
  DUNE_SMOKE_PROFILE_SAMPLES          Same as --profile-samples.
  DUNE_SMOKE_PROFILE_CONTEXT          Same as --profile-context.
  DUNE_SMOKE_PROFILE_RUN_MODE         Same as --profile-run-mode.
  DUNE_SMOKE_OUTPUT                   Same as --output.
  DUNE_SMOKE_IOS_SIMULATOR            Same as --ios-simulator.
  ADB                                 adb executable. Default: adb.
  ANDROID_EMULATOR                    emulator executable override.
  DUNE_SMOKE_CONTROL_URL              Override control URL for all targets.
  DUNE_SMOKE_CONTROL_URL_ANDROID      Override per-target control URL.
  DUNE_SMOKE_RUNNER_URL               Override runner URL the smoke app fetches
                                      its config from (all targets).
  DUNE_SMOKE_RUNNER_URL_<TARGET>      Override runner URL per target (useful
                                      for wireless iOS/Android needing a host
                                      LAN IP instead of localhost).
  DUNE_SMOKE_RUNNER_PORT              Same as --runner-port.
  DUNE_SMOKE_RUNNER_BIND_ADDRESS      Same as --runner-bind-address.
  DUNE_SMOKE_LAN_HOST                 Override the ordinary-LAN control host.
  DUNE_SMOKE_LAN_HOST_<TARGET>        Override it for one target.
  DUNE_SMOKE_RUNNER_TOKEN             Optional stable runner auth token. When
                                      unset, one is created under .dart_tool.
  DUNE_SMOKE_<TARGET>_DEVICE          Per-target Flutter device id.
''');
}
