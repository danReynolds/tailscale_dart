// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../test/e2e/support/peer_process.dart';
import 'profile/result_analysis.dart';

const _peerResponse = 'tailscale-release-perf-peer';

Future<void> main(List<String> args) async {
  final options = _RunnerOptions.parse(args);
  final repo = Directory.current.absolute;
  if (!File('${repo.path}/pubspec.yaml').existsSync() ||
      !File('${repo.path}/benchmark/profile/probe.dart').existsSync()) {
    stderr.writeln('Run this command from the tailscale package root.');
    exitCode = 2;
    return;
  }

  final baselineVersion = options.baselineVersion ?? _readBaseline(repo);
  final tempRoot = await Directory.systemTemp.createTemp(
    'tailscale_release_perf_',
  );
  final composeProject = 'tailscale-perf-$pid';
  final composeFile = '${repo.path}/test/e2e/docker-compose.yml';
  final port = await _findFreePort();
  final composeEnvironment = <String, String>{
    ...Platform.environment,
    'HEADSCALE_PORT': '$port',
  };
  final controlUrl = 'http://localhost:$port';

  PeerProcess? peer;
  var composeStarted = false;
  try {
    print('Preparing release comparison projects...');
    final release = await _prepareTarget(
      root: tempRoot,
      repo: repo,
      name: 'release',
      dependency: baselineVersion,
      current: false,
    );
    final current = await _prepareTarget(
      root: tempRoot,
      repo: repo,
      name: 'current',
      dependency: repo.path,
      current: true,
    );

    print('Warming native builds outside the timed region...');
    await _warmTarget(release);
    await _warmTarget(current);

    print('Starting isolated Headscale on port $port...');
    await _runChecked('docker', <String>[
      'compose',
      '-p',
      composeProject,
      '-f',
      composeFile,
      'up',
      '-d',
      '--wait',
    ], environment: composeEnvironment);
    composeStarted = true;
    await _waitForHeadscale(controlUrl);
    await _createHeadscaleUser(
      composeProject: composeProject,
      composeFile: composeFile,
      environment: composeEnvironment,
    );
    final ephemeralKey = await _createHeadscaleKey(
      composeProject: composeProject,
      composeFile: composeFile,
      environment: composeEnvironment,
      ephemeral: true,
    );
    final persistentKey = await _createHeadscaleKey(
      composeProject: composeProject,
      composeFile: composeFile,
      environment: composeEnvironment,
      ephemeral: false,
    );

    print('Starting fixed current-version HTTP/TCP/UDP peer...');
    peer = await PeerProcess.spawn(
      stateDir: '${tempRoot.path}/peer-state',
      appId: 'dev.tailscale.dart.benchmark.releaseCompare.peer.$pid',
      hostname: 'release-perf-peer-$pid',
      controlUrl: controlUrl,
      authKey: ephemeralKey,
      ephemeral: true,
      responseBody: _peerResponse,
    );

    final records = <Map<String, Object?>>[];
    final targets = <_Target>[release, current];
    for (var trial = 1; trial <= options.trials; trial++) {
      final order = trial.isOdd ? targets : targets.reversed.toList();
      for (final target in order) {
        print(
          'Trial $trial/${options.trials}: ${target.name} '
          'ephemeral public-API profile...',
        );
        records.addAll(
          await _runProbe(
            target,
            trial: trial,
            mode: 'ephemeral',
            stateDir: '${tempRoot.path}/state/${target.name}/ephemeral-$trial',
            appId:
                'dev.tailscale.dart.benchmark.releaseCompare.'
                '${target.name}.ephemeral.$pid.$trial',
            hostname: 'perf-${target.name}-ephemeral-$pid-$trial',
            controlUrl: controlUrl,
            authKey: ephemeralKey,
            peerIp: peer.ipv4,
            iterations: options.iterations,
            bulkIterations: options.bulkIterations,
          ),
        );
      }
    }

    for (var trial = 1; trial <= options.trials; trial++) {
      final order = trial.isOdd ? targets : targets.reversed.toList();
      for (final target in order) {
        final stateDir =
            '${tempRoot.path}/state/${target.name}/persistent-$trial';
        final appId =
            'dev.tailscale.dart.benchmark.releaseCompare.'
            '${target.name}.persistent.$pid.$trial';
        final hostname = 'perf-${target.name}-persistent-$pid-$trial';
        print(
          'Trial $trial/${options.trials}: ${target.name} '
          'persistent enrollment...',
        );
        final enrolled = await _runProbe(
          target,
          trial: trial,
          mode: 'persistent-enroll',
          stateDir: stateDir,
          appId: appId,
          hostname: hostname,
          controlUrl: controlUrl,
          authKey: persistentKey,
          iterations: options.iterations,
          bulkIterations: options.bulkIterations,
        );
        records.addAll(enrolled);
        final enrolledIpv4 = _fact(enrolled, 'ipv4');

        print(
          'Trial $trial/${options.trials}: ${target.name} '
          'persistent restart...',
        );
        records.addAll(
          await _runProbe(
            target,
            trial: trial,
            mode: 'persistent-restart',
            stateDir: stateDir,
            appId: appId,
            hostname: hostname,
            controlUrl: controlUrl,
            expectedIpv4: enrolledIpv4,
            iterations: options.iterations,
            bulkIterations: options.bulkIterations,
          ),
        );
      }
    }

    final comparisons = summarizePerfRecords(records);
    if (comparisons.isEmpty) {
      throw StateError('comparison produced no metrics');
    }
    _printComparisons(comparisons, baselineVersion);

    final output = options.outputPath == null
        ? '${Directory.systemTemp.path}/tailscale-release-perf-'
              '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json'
        : File(options.outputPath!).absolute.path;
    final currentCommit = await _gitHead(repo);
    final currentVersion = _readPackageVersion(repo);
    final report = <String, Object?>{
      'schema': 1,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'mode': options.quick ? 'quick' : 'full',
      'baseline': <String, Object?>{
        'package': 'tailscale',
        'version': baselineVersion,
      },
      'current': <String, Object?>{
        'package': 'tailscale',
        'version': currentVersion,
        // The commit identifies the measured checkout. Keeping reports
        // relocatable avoids leaking a developer-specific absolute path when
        // canonical evidence is checked in under benchmark/results.
        'path': '.',
        'commit': currentCommit,
        'dirty': await _gitDirty(repo),
      },
      'environment': <String, Object?>{
        'dart': Platform.version,
        'operatingSystem': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'trials': options.trials,
        'iterations': options.iterations,
        'bulkIterations': options.bulkIterations,
      },
      'records': records,
      'comparisons': comparisons.map((value) => value.toJson()).toList(),
    };
    final outputFile = File(output);
    outputFile.parent.createSync(recursive: true);
    outputFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    print('\nRaw comparison report: ${outputFile.path}');
  } finally {
    if (peer != null) {
      print('Stopping benchmark peer...');
      await peer.shutdown();
    }
    if (composeStarted) {
      print('Stopping isolated Headscale...');
      final result = await Process.run('docker', <String>[
        'compose',
        '-p',
        composeProject,
        '-f',
        composeFile,
        'down',
        '-v',
      ], environment: composeEnvironment);
      if (result.exitCode != 0) {
        stderr.writeln('Headscale cleanup failed: ${result.stderr}');
      }
    }
    if (options.keepTemp) {
      print('Kept temporary projects: ${tempRoot.path}');
    } else {
      try {
        tempRoot.deleteSync(recursive: true);
      } catch (error) {
        stderr.writeln('Temporary project cleanup failed: $error');
      }
    }
  }
}

String _readPackageVersion(Directory repo) {
  final contents = File('${repo.path}/pubspec.yaml').readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) {
    throw const FormatException('pubspec.yaml is missing a package version');
  }
  return match.group(1)!;
}

String _readBaseline(Directory repo) {
  final decoded = jsonDecode(
    File('${repo.path}/benchmark/profile/baseline.json').readAsStringSync(),
  );
  if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
    throw const FormatException('invalid release performance baseline');
  }
  final release = decoded['release'];
  if (release is! String || release.isEmpty) {
    throw const FormatException('release performance baseline is missing');
  }
  return release;
}

Future<_Target> _prepareTarget({
  required Directory root,
  required Directory repo,
  required String name,
  required String dependency,
  required bool current,
}) async {
  final directory = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  final bin = Directory('${directory.path}/bin')..createSync(recursive: true);
  File(
    '${repo.path}/benchmark/profile/probe.dart',
  ).copySync('${bin.path}/probe.dart');
  if (current) {
    File(
      '${repo.path}/test/e2e/support/test_keybay_backend.dart',
    ).copySync('${bin.path}/test_custody_adapter.dart');
  } else {
    File(
      '${bin.path}/test_custody_adapter.dart',
    ).writeAsStringSync('void installE2ETestKeybay(String stateRoot) {}\n');
  }

  final dependencyYaml = current
      ? "  tailscale:\n    path: '${_yamlQuote(dependency)}'\n"
            '  keybay: 0.1.0\n'
            '  path: ^1.9.1\n'
      : "  tailscale: ${_yamlQuote(dependency)}\n";
  File('${directory.path}/pubspec.yaml').writeAsStringSync(
    'name: tailscale_release_perf_$name\n'
    'publish_to: none\n'
    'environment:\n'
    "  sdk: '>=3.12.0 <4.0.0'\n"
    'dependencies:\n'
    '$dependencyYaml',
  );
  await _runChecked(
    Platform.resolvedExecutable,
    const <String>['pub', 'get'],
    workingDirectory: directory.path,
    environment: <String, String>{
      ...Platform.environment,
      'DART_SUPPRESS_ANALYTICS': 'true',
    },
  );
  return _Target(name: name, directory: directory);
}

String _yamlQuote(String value) => value.replaceAll("'", "''");

Future<void> _warmTarget(_Target target) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    const <String>['run', 'bin/probe.dart'],
    workingDirectory: target.directory.path,
    environment: <String, String>{
      ...Platform.environment,
      'DART_SUPPRESS_ANALYTICS': 'true',
      'PERF_MODE': 'build-warmup',
    },
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      Platform.resolvedExecutable,
      const <String>['run', 'bin/probe.dart'],
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}

Future<List<Map<String, Object?>>> _runProbe(
  _Target target, {
  required int trial,
  required String mode,
  required String stateDir,
  required String appId,
  required String hostname,
  required String controlUrl,
  required int iterations,
  required int bulkIterations,
  String? authKey,
  String? peerIp,
  String? expectedIpv4,
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    const <String>['run', 'bin/probe.dart'],
    workingDirectory: target.directory.path,
    environment: <String, String>{
      ...Platform.environment,
      'DART_SUPPRESS_ANALYTICS': 'true',
      'PERF_MODE': mode,
      'PERF_STATE_DIR': stateDir,
      'PERF_APP_ID': appId,
      'PERF_HOSTNAME': hostname,
      'PERF_CONTROL_URL': controlUrl,
      'PERF_PEER_RESPONSE': _peerResponse,
      'PERF_ITERATIONS': '$iterations',
      'PERF_BULK_ITERATIONS': '$bulkIterations',
      'PERF_AUTH_KEY': ?authKey,
      'PERF_PEER_IP': ?peerIp,
      'PERF_EXPECTED_IPV4': ?expectedIpv4,
    },
  );
  final records = <Map<String, Object?>>[];
  final stderrBuffer = StringBuffer();
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((line) {
        final record = _parseProbeLine(
          line,
          target: target.name,
          trial: trial,
          phase: mode,
        );
        if (record != null) records.add(record);
      });
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .forEach(stderrBuffer.write);

  late final int processExitCode;
  try {
    processExitCode = await process.exitCode.timeout(
      const Duration(minutes: 3),
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
    final lastMetric = records.lastWhere(
      (record) => record['kind'] == 'metric',
      orElse: () => <String, Object?>{},
    )['scenario'];
    throw TimeoutException(
      '${target.name} $mode probe exceeded 3 minutes '
      '(last metric: ${lastMetric ?? 'none'})',
    );
  }
  await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
  if (processExitCode != 0 ||
      records.any((record) => record['kind'] == 'error')) {
    throw ProcessException(
      Platform.resolvedExecutable,
      const <String>['run', 'bin/probe.dart'],
      stderrBuffer.toString(),
      processExitCode,
    );
  }
  if (!records.any((record) => record['kind'] == 'complete')) {
    throw ProcessException(
      Platform.resolvedExecutable,
      const <String>['run', 'bin/probe.dart'],
      'probe exited without a completion record\n$stderrBuffer',
      processExitCode,
    );
  }
  return records;
}

Map<String, Object?>? _parseProbeLine(
  String line, {
  required String target,
  required int trial,
  required String phase,
}) {
  final marker = line.indexOf('PERF_JSON ');
  if (marker < 0) return null;
  final decoded = jsonDecode(line.substring(marker + 'PERF_JSON '.length));
  if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
    throw FormatException('invalid probe record: $line');
  }
  return <String, Object?>{
    ...decoded,
    'target': target,
    'trial': trial,
    'phase': phase,
  };
}

String _fact(List<Map<String, Object?>> records, String name) {
  for (final record in records) {
    if (record['kind'] == 'fact' && record['name'] == name) {
      final value = record['value'];
      if (value is String && value.isNotEmpty) return value;
    }
  }
  throw StateError('probe did not emit fact $name');
}

Future<void> _createHeadscaleUser({
  required String composeProject,
  required String composeFile,
  required Map<String, String> environment,
}) async {
  final result = await Process.run('docker', <String>[
    'compose',
    '-p',
    composeProject,
    '-f',
    composeFile,
    'exec',
    '-T',
    'headscale',
    'headscale',
    'users',
    'create',
    'tailscale-perf',
  ], environment: environment);
  if (result.exitCode != 0 &&
      !(result.stderr as String).contains('already exists')) {
    throw ProcessException('docker', const <String>[], '${result.stderr}');
  }
}

Future<String> _createHeadscaleKey({
  required String composeProject,
  required String composeFile,
  required Map<String, String> environment,
  required bool ephemeral,
}) async {
  final arguments = <String>[
    'compose',
    '-p',
    composeProject,
    '-f',
    composeFile,
    'exec',
    '-T',
    'headscale',
    'headscale',
    'preauthkeys',
    'create',
    '--user',
    'tailscale-perf',
    '--reusable',
    if (ephemeral) '--ephemeral',
    '--expiration',
    '1h',
  ];
  final result = await Process.run(
    'docker',
    arguments,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw ProcessException('docker', arguments, '${result.stderr}');
  }
  final lines = const LineSplitter()
      .convert(result.stdout as String)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) throw StateError('Headscale did not return an auth key');
  return lines.last;
}

Future<int> _findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForHeadscale(String controlUrl) async {
  final client = HttpClient();
  try {
    Object? lastError;
    for (var attempt = 0; attempt < 60; attempt++) {
      try {
        final request = await client.getUrl(Uri.parse('$controlUrl/health'));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == 200) return;
        lastError = 'HTTP ${response.statusCode}';
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('Headscale did not become healthy: $lastError');
  } finally {
    client.close(force: true);
  }
}

Future<void> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}

Future<String> _gitHead(Directory repo) async {
  final result = await Process.run('git', const <String>[
    'rev-parse',
    'HEAD',
  ], workingDirectory: repo.path);
  return result.exitCode == 0 ? (result.stdout as String).trim() : 'unknown';
}

Future<bool> _gitDirty(Directory repo) async {
  final result = await Process.run('git', const <String>[
    'status',
    '--porcelain',
  ], workingDirectory: repo.path);
  return result.exitCode != 0 || (result.stdout as String).trim().isNotEmpty;
}

void _printComparisons(
  List<PerfComparison> comparisons,
  String baselineVersion,
) {
  print('\n=== tailscale $baselineVersion versus current ===');
  _printGroup(
    'Operation latency',
    comparisons.where(
      (value) =>
          value.unit == 'microseconds' &&
          !value.scenario.endsWith('.event_loop_lag'),
    ),
  );
  _printGroup(
    'Main-isolate event-loop lag',
    comparisons.where((value) => value.scenario.endsWith('.event_loop_lag')),
    primaryP95: true,
  );
  _printGroup(
    'Throughput',
    comparisons.where((value) => value.unit == 'mib_per_second'),
  );
  _printGroup(
    'Resident memory',
    comparisons.where((value) => value.unit == 'bytes'),
  );
}

void _printGroup(
  String title,
  Iterable<PerfComparison> values, {
  bool primaryP95 = false,
}) {
  final rows = values.toList();
  if (rows.isEmpty) return;
  print('\n$title');
  print(
    '${'scenario'.padRight(46)} '
    '${(primaryP95 ? 'release p95' : 'release p50').padLeft(12)} '
    '${(primaryP95 ? 'current p95' : 'current p50').padLeft(12)} '
    '${'delta'.padLeft(9)} '
    '${(primaryP95 ? 'current p50' : 'current p95').padLeft(12)} '
    "${'W/L'.padLeft(7)}  verdict",
  );
  for (final row in rows) {
    final deltaValue = row.currentDeltaPercent;
    final delta = deltaValue != null
        ? '${deltaValue >= 0 ? '+' : ''}'
              '${deltaValue.toStringAsFixed(1)}%'
        : 'n/a';
    final baselinePrimary = primaryP95 ? row.baselineP95 : row.baselineP50;
    final currentPrimary = primaryP95 ? row.currentP95 : row.currentP50;
    final currentSecondary = primaryP95 ? row.currentP50 : row.currentP95;
    print(
      '${row.scenario.padRight(46)} '
      '${_formatValue(baselinePrimary, row.unit).padLeft(12)} '
      '${_formatValue(currentPrimary, row.unit).padLeft(12)} '
      '${delta.padLeft(9)} '
      '${_formatValue(currentSecondary, row.unit).padLeft(12)} '
      '${'${row.currentWins}/${row.currentLosses}'.padLeft(7)}  '
      '${row.verdict}',
    );
  }
}

String _formatValue(double value, String unit) => switch (unit) {
  'microseconds' => '${(value / 1000).toStringAsFixed(2)} ms',
  'mib_per_second' => '${value.toStringAsFixed(1)} MiB/s',
  'bytes' => '${(value / (1 << 20)).toStringAsFixed(1)} MiB',
  _ => value.toStringAsFixed(2),
};

final class _Target {
  const _Target({required this.name, required this.directory});

  final String name;
  final Directory directory;
}

final class _RunnerOptions {
  const _RunnerOptions({
    required this.quick,
    required this.trials,
    required this.iterations,
    required this.bulkIterations,
    required this.baselineVersion,
    required this.outputPath,
    required this.keepTemp,
  });

  factory _RunnerOptions.parse(List<String> arguments) {
    final quick = arguments.contains('--quick');
    String? value(String prefix) {
      for (final argument in arguments) {
        if (argument.startsWith('$prefix=')) {
          return argument.substring(prefix.length + 1);
        }
      }
      return null;
    }

    final trials = int.parse(value('--trials') ?? (quick ? '1' : '5'));
    final iterations = int.parse(value('--iterations') ?? (quick ? '5' : '50'));
    final bulkIterations = int.parse(value('--bulk-iterations') ?? '1');
    if (trials <= 0 || iterations <= 0 || bulkIterations <= 0) {
      throw ArgumentError('trial and iteration counts must be positive');
    }
    return _RunnerOptions(
      quick: quick,
      trials: trials,
      iterations: iterations,
      bulkIterations: bulkIterations,
      baselineVersion: value('--baseline'),
      outputPath: value('--output'),
      keepTemp: arguments.contains('--keep-temp'),
    );
  }

  final bool quick;
  final int trials;
  final int iterations;
  final int bulkIterations;
  final String? baselineVersion;
  final String? outputPath;
  final bool keepTemp;
}
