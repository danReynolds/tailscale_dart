// ignore_for_file: cancel_subscriptions

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _knownTargets = ['macos', 'ios', 'android', 'linux'];
const _defaultTargets = ['macos', 'ios', 'android'];
const _resultPrefix = 'DUNE_SMOKE_RESULT ';

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
  Process? _launchedAndroidEmulator;
  HttpServer? _runnerServer;
  String? _currentAuthKey;
  String? _currentTargetIp;
  final Map<String, Completer<Map<String, Object?>>> _resultCompleters = {};

  Future<bool> run() async {
    final stateRoot = Directory.systemTemp.createTempSync('dune_smoke_matrix_');
    _ManagedPeer? peer;
    var headscaleStarted = false;
    // Pre-builds run in parallel with peer setup since auth key + target IP
    // are no longer compile-time constants. The futures resolve to the path
    // of the built artifact, used by `flutter run --use-application-binary`.
    final preBuildFutures = <String, Future<String>>{};
    if (config.preBuild) {
      for (final target in config.targets) {
        if (_buildArgsFor(target) == null) continue;
        preBuildFutures[target] = _preBuildTarget(target);
      }
    }
    try {
      await _startRunnerServer();
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
      if (config.targets.contains('ios') && !_hasIosSimulator(devices)) {
        await _launchIosSimulator(config.iosSimulator);
        devices = await _waitForFlutterDevice('ios');
      }

      final runs = config.targets
          .map((target) => _TargetLaunch(target, _deviceIdFor(target, devices)))
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
        final state = result.skipped
            ? 'SKIP'
            : result.ok
            ? 'PASS'
            : 'FAIL';
        _log('  ${result.target}: $state ${result.message}');
      }

      if (config.strict && skipped.isNotEmpty) return false;
      return failed.isEmpty;
    } finally {
      // Cleanup tasks are independent: parallelize the foreground ones and
      // detach `compose down -v` so the runner exits as soon as the summary
      // is reported. Detached docker continues teardown in the background.
      if (headscaleStarted && !config.keepHeadscale) {
        _log('detaching docker compose down -v in background');
        await Process.start(
          config.docker,
          ['compose', '-f', composeFile, 'down', '-v'],
          environment: {'HEADSCALE_PORT': config.headscalePort},
          mode: ProcessStartMode.detached,
        );
      }
      await Future.wait(<Future<void>>[
        if (peer != null) peer.stop(),
        Future(() {
          try {
            stateRoot.deleteSync(recursive: true);
          } catch (_) {}
        }),
        _stopLaunchedAndroidEmulator(),
        _stopRunnerServer(),
        // Drain any still-pending pre-builds so the runner doesn't leave
        // stray flutter build subprocesses behind. Errors are absorbed.
        for (final future in preBuildFutures.values)
          future.then((_) {}, onError: (Object _) {}),
      ]);
    }
  }

  List<String>? _buildArgsFor(String target) {
    switch (target) {
      case 'macos':
        return ['build', 'macos', '--debug'];
      case 'ios':
        // Pre-build for the iOS simulator. If the user pinned an iOS device
        // override, fall back to flutter run's inline build (skip pre-build).
        if (config.deviceOverrides.containsKey('ios')) return null;
        return [
          'build',
          'ios',
          '--simulator',
          '--debug',
          '--no-codesign',
        ];
      case 'android':
        return ['build', 'apk', '--${config.androidRunMode}'];
      default:
        return null;
    }
  }

  String _binaryPathFor(String target) {
    switch (target) {
      case 'macos':
        return '$smokeAppDir/build/macos/Build/Products/Debug/'
            'dune_smoke_flutter.app';
      case 'ios':
        return '$smokeAppDir/build/ios/iphonesimulator/Runner.app';
      case 'android':
        final mode = config.androidRunMode;
        return '$smokeAppDir/build/app/outputs/flutter-apk/app-$mode.apk';
      default:
        throw StateError('no binary path for $target');
    }
  }

  Future<String> _preBuildTarget(String target) async {
    final args = _buildArgsFor(target);
    if (args == null) {
      throw StateError('pre-build not supported for $target');
    }
    _log('pre-building $target ($args)');
    final sw = Stopwatch()..start();
    final process = await Process.start(
      config.flutter,
      args,
      workingDirectory: smokeAppDir,
    );
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stdout.writeln('[$target/build] $line'));
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[$target/build] $line'));
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
      InternetAddress.anyIPv4,
      config.runnerPort,
    );
    _log('runner HTTP server listening on port ${config.runnerPort}');
    unawaited(_serveRunnerRequests());
  }

  Future<void> _stopRunnerServer() async {
    final server = _runnerServer;
    _runnerServer = null;
    if (server == null) return;
    await server.close(force: true);
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
    if (request.method == 'GET' && path == '/config') {
      final body = <String, Object?>{
        'authKey': _currentAuthKey ?? '',
        'controlUrl': _controlUrlFor(session),
        'targetIp': _currentTargetIp ?? '',
        'hostname': 'dune-smoke-$session',
        'stateSuffix': '$session-$_runStartMillis',
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
      if (data != null && completer != null && !completer.isCompleted) {
        completer.complete(data);
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  String _runnerUrlFor(String target) {
    final specific = Platform
        .environment['DUNE_SMOKE_RUNNER_URL_${target.toUpperCase()}'];
    if (specific != null && specific.isNotEmpty) return specific;
    final shared = Platform.environment['DUNE_SMOKE_RUNNER_URL'];
    if (shared != null && shared.isNotEmpty) return shared;
    if (target == 'android') return 'http://10.0.2.2:${config.runnerPort}';
    return 'http://localhost:${config.runnerPort}';
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

  Future<List<_FlutterDevice>> _waitForFlutterDevice(String target) async {
    for (var i = 0; i < 90; i++) {
      final devices = await _flutterDevices();
      if (_deviceIdFor(target, devices) != null) return devices;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return _flutterDevices();
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

  Future<_TargetRun> _runFlutterTarget({
    required String target,
    required String deviceId,
    Future<String>? preBuildFuture,
  }) async {
    if (target == 'android') {
      await _waitForAndroidReady(deviceId);
    }
    String? binaryPath;
    if (preBuildFuture != null) {
      try {
        binaryPath = await preBuildFuture;
        _log('$target using pre-built binary at $binaryPath');
      } catch (error) {
        _log('$target pre-build failed: $error; falling back to inline build');
      }
    }
    final runnerUrl = _runnerUrlFor(target);
    _log('running $target smoke on Flutter device $deviceId');
    final runMode = target == 'android' ? config.androidRunMode : 'debug';
    final process = await Process.start(config.flutter, [
      'run',
      '-d',
      deviceId,
      '--$runMode',
      if (binaryPath != null) ...['--use-application-binary', binaryPath],
      '--dart-define=DUNE_SMOKE_RUNNER_URL=$runnerUrl',
      '--dart-define=DUNE_SMOKE_SESSION=$target',
    ], workingDirectory: smokeAppDir);

    final result = Completer<_TargetRun>();
    final httpResult = Completer<Map<String, Object?>>();
    _resultCompleters[target] = httpResult;
    unawaited(
      httpResult.future.then((data) {
        if (result.isCompleted) return;
        final ok = data['ok'] == true;
        final duration = data['durationMs'];
        result.complete(
          _TargetRun(
            target: target,
            ok: ok,
            skipped: false,
            message: ok
                ? 'completed in ${duration ?? '?'}ms'
                : (data['error'] as String? ?? 'probe failed'),
          ),
        );
      }),
    );

    void handleLine(String stream, String line) {
      stdout.writeln('[$target/$stream] $line');
      final resultIndex = line.indexOf(_resultPrefix);
      if (resultIndex < 0 || result.isCompleted) return;
      // Stdout result is a fallback path if /result POST never lands.
      final jsonText = line.substring(resultIndex + _resultPrefix.length);
      try {
        final decoded = jsonDecode(jsonText) as Map<String, Object?>;
        final ok = decoded['ok'] == true;
        final duration = decoded['durationMs'];
        result.complete(
          _TargetRun(
            target: target,
            ok: ok,
            skipped: false,
            message: ok
                ? 'completed in ${duration ?? '?'}ms'
                : (decoded['error'] as String? ?? 'probe failed'),
          ),
        );
      } catch (error) {
        result.complete(
          _TargetRun(
            target: target,
            ok: false,
            skipped: false,
            message: 'invalid result JSON: $error',
          ),
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
        if (!result.isCompleted) {
          result.complete(
            _TargetRun(
              target: target,
              ok: false,
              skipped: false,
              message: 'flutter run exited before smoke result: $code',
            ),
          );
        }
      }),
    );

    try {
      return await result.future.timeout(config.timeout);
    } on TimeoutException {
      return _TargetRun(
        target: target,
        ok: false,
        skipped: false,
        message: 'timed out after ${config.timeout.inSeconds}s',
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

  Future<_TargetRun> _runOrSkipTarget(
    _TargetLaunch run,
    Map<String, Future<String>> preBuildFutures,
  ) async {
    final deviceId = run.deviceId;
    if (deviceId == null) {
      final skipped = _TargetRun.skipped(run.target, 'no Flutter device found');
      _log('${run.target.toUpperCase()} SKIP ${skipped.message}');
      return skipped;
    }
    return _runFlutterTarget(
      target: run.target,
      deviceId: deviceId,
      preBuildFuture: preBuildFutures[run.target],
    );
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
        .listen((line) => stdout.writeln('[android-emulator/out] $line'));
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[android-emulator/err] $line'));
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
      throw StateError(
        'failed to launch iOS Simulator $simulatorId: $err',
      );
    }
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
          _log('Android device $deviceId is ready');
          return;
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
    throw TimeoutException(
      'Android device $deviceId did not become ready: $lastStatus',
    );
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
      '--enable-experiment=native-assets',
      'bin/demo_node.dart',
      'serve',
      '--state-dir',
      stateDir,
      '--hostname',
      'dune-smoke-peer',
      '--auth-key',
      authKey,
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
          stdout.writeln('[peer/out] $line');
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
        .listen((line) => stderr.writeln('[peer/err] $line'));

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
  });

  final String id;
  final String targetPlatform;
  final String platformType;
  final bool emulator;

  static _FlutterDevice fromJson(Map<String, Object?> json) => _FlutterDevice(
    id: json['id'] as String? ?? '',
    targetPlatform: json['targetPlatform'] as String? ?? '',
    platformType: json['platformType'] as String? ?? '',
    emulator: json['emulator'] == true,
  );
}

final class _TargetLaunch {
  const _TargetLaunch(this.target, this.deviceId);

  final String target;
  final String? deviceId;
}

final class _TargetRun {
  const _TargetRun({
    required this.target,
    required this.ok,
    required this.skipped,
    required this.message,
  });

  factory _TargetRun.skipped(String target, String message) =>
      _TargetRun(target: target, ok: true, skipped: true, message: message);

  final String target;
  final bool ok;
  final bool skipped;
  final String message;
}

final class _Config {
  const _Config({
    required this.targets,
    required this.deviceOverrides,
    required this.timeout,
    required this.headscalePort,
    required this.runnerPort,
    required this.dart,
    required this.flutter,
    required this.docker,
    required this.adb,
    required this.emulator,
    required this.androidAvd,
    required this.iosSimulator,
    required this.androidRunMode,
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
  final String dart;
  final String flutter;
  final String docker;
  final String adb;
  final String? emulator;
  final String? androidAvd;
  final String iosSimulator;
  final String androidRunMode;
  final int jobs;
  final bool keepHeadscale;
  final bool keepAndroidEmulator;
  final bool preBuild;
  final bool strict;
  final bool help;

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

    final deviceOverrides = <String, String>{};
    for (final target in _defaultTargets) {
      final value =
          options['$target-device'] ??
          Platform.environment['DUNE_SMOKE_${target.toUpperCase()}_DEVICE'];
      if (value != null && value.isNotEmpty) {
        deviceOverrides[target] = value;
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
  Map<String, String>? environment,
  bool allowFailure = false,
}) async {
  _log('\$ $executable ${args.join(' ')}');
  final result = await Process.run(executable, args, environment: environment);
  if (result.stdout case final String out when out.trim().isNotEmpty) {
    stdout.write(out);
  }
  if (result.stderr case final String err when err.trim().isNotEmpty) {
    stderr.write(err);
  }
  if (!allowFailure && result.exitCode != 0) {
    throw StateError('$executable exited with ${result.exitCode}');
  }
  return result;
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
  --android-avd NAME                  Launch this Android AVD if no Android device is visible.
  --android-run-mode debug|profile    Android Flutter run mode. Default: profile.
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
  DUNE_SMOKE_<TARGET>_DEVICE          Per-target Flutter device id.
''');
}
