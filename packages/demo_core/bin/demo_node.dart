import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:demo_core/demo_core.dart';

const _defaultReadyTimeout = Duration(seconds: 120);
const _defaultProbeTimeout = Duration(seconds: 60);

Future<void> main(List<String> args) async {
  final parsed = _Args.parse(args);
  if (parsed.help || parsed.command == null) {
    _printUsage();
    return;
  }

  try {
    switch (parsed.command) {
      case 'serve':
        await _serve(parsed);
      case 'probe':
        final ok = await _probe(parsed);
        if (!ok) exitCode = 1;
      case 'pair':
        final ok = await _pair(parsed);
        if (!ok) exitCode = 1;
      default:
        throw _UsageException('unknown command ${parsed.command}');
    }
  } on _UsageException catch (error) {
    stderr.writeln('demo_node: ${error.message}');
    stderr.writeln('');
    _printUsage();
    exitCode = 64;
  } catch (error, stackTrace) {
    stderr.writeln('demo_node: $error');
    if (parsed.flag('debug')) stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<void> _serve(_Args args) async {
  final stateDir = args.optionOrEnv('state-dir', 'STATE_DIR');
  if (stateDir == null || stateDir.isEmpty) {
    throw const _UsageException('serve requires --state-dir or STATE_DIR');
  }
  final hostname = args.optionOrEnv('hostname', 'HOSTNAME') ?? 'demo-node';
  final authKey = args.optionOrEnv('auth-key', 'AUTH_KEY');
  final controlUrl = _optionalUri(
    args.optionOrEnv('control-url', 'CONTROL_URL'),
  );
  final demo = DemoCore();
  final subscriptions = <StreamSubscription<Object?>>[
    demo.onStateChange.listen((state) => stderr.writeln('state ${state.name}')),
    demo.onError.listen(
      (error) => stderr.writeln('runtime-error ${error.message}'),
    ),
  ];

  final status = await _upAndWaitRunning(
    demo,
    stateDir: stateDir,
    hostname: hostname,
    authKey: authKey,
    controlUrl: controlUrl,
    verbose: args.flag('verbose'),
  );
  final services = await demo.startServices();
  final ip = status.ipv4 ?? services.localIp;
  stdout.writeln(
    'READY ${jsonEncode({'hostname': hostname, 'ip': ip, 'services': _servicesToJson(services)})}',
  );
  await stdout.flush();

  final stop = Completer<void>();
  StreamSubscription<String>? commandSub;
  if (args.flag('stdin-control')) {
    commandSub = utf8.decoder
        .bind(stdin)
        .transform(const LineSplitter())
        .listen(
          (line) {
            unawaited(_handleServeCommand(demo, line, stop));
          },
          onDone: () {
            if (!stop.isCompleted) stop.complete();
          },
        );
  }
  final signalSubs = _listenForStopSignals(stop);

  await stop.future;

  await commandSub?.cancel();
  for (final sub in signalSubs) {
    await sub.cancel();
  }
  for (final sub in subscriptions) {
    await sub.cancel();
  }
  await demo.down();
}

Future<void> _handleServeCommand(
  DemoCore demo,
  String line,
  Completer<void> stop,
) async {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return;
  if (trimmed == 'STOP') {
    if (!stop.isCompleted) stop.complete();
    return;
  }
  if (trimmed.startsWith('PROBE ')) {
    final nodeIp = trimmed.substring('PROBE '.length).trim();
    final report = await demo.probeNode(nodeIp, timeout: _defaultProbeTimeout);
    stdout.writeln('PROBE_RESULT ${jsonEncode(_reportToJson(report))}');
    await stdout.flush();
    return;
  }
  stdout.writeln(
    'ERROR ${jsonEncode({'message': 'unknown command', 'command': trimmed})}',
  );
  await stdout.flush();
}

Future<bool> _probe(_Args args) async {
  final stateDir = args.optionOrEnv('state-dir', 'STATE_DIR');
  if (stateDir == null || stateDir.isEmpty) {
    throw const _UsageException('probe requires --state-dir or STATE_DIR');
  }
  final nodeIp = args.optionOrEnv('node', 'NODE_IP');
  if (nodeIp == null || nodeIp.isEmpty) {
    throw const _UsageException('probe requires --node or NODE_IP');
  }
  final hostname = args.optionOrEnv('hostname', 'HOSTNAME') ?? 'demo-probe';
  final authKey = args.optionOrEnv('auth-key', 'AUTH_KEY');
  final controlUrl = _optionalUri(
    args.optionOrEnv('control-url', 'CONTROL_URL'),
  );
  final demo = DemoCore();
  await _upAndWaitRunning(
    demo,
    stateDir: stateDir,
    hostname: hostname,
    authKey: authKey,
    controlUrl: controlUrl,
    verbose: args.flag('verbose'),
  );
  try {
    final report = await demo.probeNode(nodeIp, timeout: _defaultProbeTimeout);
    _printReport(report, json: args.flag('json'));
    return report.ok;
  } finally {
    await demo.down();
  }
}

Future<bool> _pair(_Args args) async {
  final authKey = args.optionOrEnv('auth-key', 'AUTH_KEY');
  if (authKey == null || authKey.isEmpty) {
    throw const _UsageException('pair requires --auth-key or AUTH_KEY');
  }
  final controlUrl = args.optionOrEnv('control-url', 'CONTROL_URL');
  final timeout = Duration(
    seconds:
        int.tryParse(args.option('timeout-seconds') ?? '') ??
        _defaultReadyTimeout.inSeconds,
  );
  final stateRoot =
      args.option('state-root') ??
      Directory.systemTemp.createTempSync('dune_demo_pair_').path;
  Directory(stateRoot).createSync(recursive: true);

  final packageRoot = _packageRoot();
  final a = await _ManagedNode.spawn(
    name: 'a',
    packageRoot: packageRoot,
    stateDir: '$stateRoot/a',
    hostname: args.option('hostname-a') ?? 'demo-local-a',
    authKey: authKey,
    controlUrl: controlUrl,
    verbose: args.flag('verbose'),
  );

  try {
    final aReady = await a.ready.timeout(timeout);
    // Start node B only after A has loaded its native asset. Running two
    // `dart run` native-asset bundling steps concurrently can race while
    // rewriting .dart_tool/lib/libtailscale.dylib on macOS.
    final b = await _ManagedNode.spawn(
      name: 'b',
      packageRoot: packageRoot,
      stateDir: '$stateRoot/b',
      hostname: args.option('hostname-b') ?? 'demo-local-b',
      authKey: authKey,
      controlUrl: controlUrl,
      verbose: args.flag('verbose'),
    );
    try {
      final bReady = await b.ready.timeout(timeout);
      stdout.writeln('PAIR_READY a=${aReady.ip} b=${bReady.ip}');

      final results = await Future.wait([
        a
            .probe(bReady.ip)
            .timeout(_defaultProbeTimeout + const Duration(seconds: 5)),
        b
            .probe(aReady.ip)
            .timeout(_defaultProbeTimeout + const Duration(seconds: 5)),
      ]);
      final ok = results.every((report) => report.ok);
      for (final report in results) {
        _printReport(report, json: args.flag('json'));
      }
      stdout.writeln('PAIR_RESULT ${ok ? 'PASS' : 'FAIL'}');

      if (args.flag('keep-alive')) {
        stdout.writeln('PAIR_KEEPALIVE stateRoot=$stateRoot');
        final stop = Completer<void>();
        final signalSubs = _listenForStopSignals(stop);
        await stop.future;
        for (final sub in signalSubs) {
          await sub.cancel();
        }
      }
      return ok;
    } finally {
      await b.stop();
    }
  } finally {
    await a.stop();
  }
}

Future<TailscaleStatus> _upAndWaitRunning(
  DemoCore demo, {
  required String stateDir,
  required String hostname,
  required String? authKey,
  required Uri? controlUrl,
  required bool verbose,
}) async {
  final running = demo.onStateChange.firstWhere((s) => s == NodeState.running);
  final status = await demo.up(
    stateDir: stateDir,
    hostname: hostname,
    authKey: authKey,
    controlUrl: controlUrl,
    logLevel: verbose ? TailscaleLogLevel.info : TailscaleLogLevel.error,
  );
  if (status.isRunning) return status;
  await running.timeout(_defaultReadyTimeout);
  return demo.status();
}

List<StreamSubscription<void>> _listenForStopSignals(Completer<void> stop) {
  StreamSubscription<void>? watch(ProcessSignal signal) {
    try {
      return signal.watch().listen((_) {
        if (!stop.isCompleted) stop.complete();
      });
    } on UnsupportedError {
      return null;
    }
  }

  return [?watch(ProcessSignal.sigint), ?watch(ProcessSignal.sigterm)];
}

Uri? _optionalUri(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return Uri.parse(value.trim());
}

Map<String, Object?> _servicesToJson(DemoServices services) => {
  'localIp': services.localIp,
  'httpTailnetPort': services.httpTailnetPort,
  'tcpPort': services.tcpPort,
  'udpPort': services.udpPort,
};

Map<String, Object?> _reportToJson(DemoProbeReport report) => {
  'nodeIp': report.nodeIp,
  'ok': report.ok,
  'results': [
    for (final result in report.results)
      {
        'kind': result.kind.name,
        'ok': result.ok,
        'durationMs': result.duration.inMilliseconds,
        'message': result.message,
      },
  ],
};

DemoProbeReport _reportFromJson(Map<String, Object?> json) {
  final results = (json['results'] as List<dynamic>? ?? const [])
      .cast<Map<String, Object?>>()
      .map((item) {
        final kindName = item['kind'] as String? ?? '';
        return DemoProbeResult(
          kind: DemoProbeKind.values.firstWhere(
            (kind) => kind.name == kindName,
            orElse: () => DemoProbeKind.ping,
          ),
          ok: item['ok'] == true,
          duration: Duration(milliseconds: item['durationMs'] as int? ?? 0),
          message: item['message'] as String? ?? '',
        );
      })
      .toList(growable: false);
  return DemoProbeReport(
    nodeIp: json['nodeIp'] as String? ?? '',
    results: results,
  );
}

void _printReport(DemoProbeReport report, {required bool json}) {
  if (json) {
    stdout.writeln(jsonEncode(_reportToJson(report)));
    return;
  }
  stdout.writeln('PROBE ${report.nodeIp}: ${report.ok ? 'PASS' : 'FAIL'}');
  for (final result in report.results) {
    stdout.writeln(
      '  ${result.ok ? 'ok ' : 'err'} ${result.kind.label} '
      '${result.duration.inMilliseconds}ms ${result.message}',
    );
  }
}

String _packageRoot() {
  var dir = File(Platform.script.toFilePath()).parent;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: demo_core')) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate demo_core package root');
    }
    dir = parent;
  }
}

final class _ReadyNode {
  const _ReadyNode({required this.ip});

  final String ip;
}

final class _ManagedNode {
  _ManagedNode._({
    required this.name,
    required this.process,
    required this.ready,
    required this.stdoutSub,
    required this.stderrSub,
  });

  final String name;
  final Process process;
  final Future<_ReadyNode> ready;
  final StreamSubscription<String> stdoutSub;
  final StreamSubscription<String> stderrSub;
  Completer<DemoProbeReport>? _pendingProbe;

  static Future<_ManagedNode> spawn({
    required String name,
    required String packageRoot,
    required String stateDir,
    required String hostname,
    required String authKey,
    required String? controlUrl,
    required bool verbose,
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      '--enable-experiment=native-assets',
      'bin/demo_node.dart',
      'serve',
      '--state-dir',
      stateDir,
      '--hostname',
      hostname,
      '--auth-key',
      authKey,
      if (controlUrl != null && controlUrl.isNotEmpty) ...[
        '--control-url',
        controlUrl,
      ],
      '--stdin-control',
      if (verbose) '--verbose',
    ], workingDirectory: packageRoot);

    late _ManagedNode node;
    final ready = Completer<_ReadyNode>();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          node._handleStdoutLine(line, ready);
        });
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[$name] $line'));

    node = _ManagedNode._(
      name: name,
      process: process,
      ready: ready.future,
      stdoutSub: stdoutSub,
      stderrSub: stderrSub,
    );
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('node $name exited before READY: $code'),
          );
        }
        final pending = node._pendingProbe;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            StateError('node $name exited during probe: $code'),
          );
        }
      }),
    );
    return node;
  }

  Future<DemoProbeReport> probe(String ip) {
    if (_pendingProbe != null) {
      throw StateError('node $name already has a pending probe');
    }
    final completer = Completer<DemoProbeReport>();
    _pendingProbe = completer;
    process.stdin.writeln('PROBE $ip');
    return completer.future.whenComplete(() => _pendingProbe = null);
  }

  Future<void> stop() async {
    process.stdin.writeln('STOP');
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }

  void _handleStdoutLine(String line, Completer<_ReadyNode> ready) {
    final readyIndex = line.indexOf('READY ');
    if (readyIndex >= 0) {
      final jsonText = line.substring(readyIndex + 'READY '.length);
      final decoded = jsonDecode(jsonText) as Map<String, Object?>;
      ready.complete(_ReadyNode(ip: decoded['ip'] as String));
      return;
    }

    final probeIndex = line.indexOf('PROBE_RESULT ');
    if (probeIndex >= 0) {
      final jsonText = line.substring(probeIndex + 'PROBE_RESULT '.length);
      final decoded = jsonDecode(jsonText) as Map<String, Object?>;
      final pending = _pendingProbe;
      if (pending != null && !pending.isCompleted) {
        pending.complete(_reportFromJson(decoded));
      }
      return;
    }

    stdout.writeln('[$name] $line');
  }
}

final class _Args {
  const _Args({
    required this.command,
    required this.options,
    required this.flags,
    required this.help,
  });

  final String? command;
  final Map<String, String> options;
  final Set<String> flags;
  final bool help;

  static _Args parse(List<String> args) {
    String? command;
    final options = <String, String>{};
    final flags = <String>{};
    var help = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-h' || arg == '--help') {
        help = true;
        continue;
      }
      if (!arg.startsWith('--')) {
        command ??= arg;
        continue;
      }
      final withoutPrefix = arg.substring(2);
      final equals = withoutPrefix.indexOf('=');
      if (equals >= 0) {
        options[withoutPrefix.substring(0, equals)] = withoutPrefix.substring(
          equals + 1,
        );
        continue;
      }
      final next = i + 1 < args.length ? args[i + 1] : null;
      if (next != null && !next.startsWith('--')) {
        options[withoutPrefix] = next;
        i++;
      } else {
        flags.add(withoutPrefix);
      }
    }

    return _Args(command: command, options: options, flags: flags, help: help);
  }

  String? option(String name) => options[name];

  String? optionOrEnv(String name, String envName) =>
      option(name) ?? Platform.environment[envName];

  bool flag(String name) => flags.contains(name);
}

final class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}

void _printUsage() {
  stdout.writeln('''
Usage:
  dart run --enable-experiment=native-assets bin/demo_node.dart serve \\
    --state-dir /tmp/dune-a --hostname demo-a --auth-key tskey-auth-...

  dart run --enable-experiment=native-assets bin/demo_node.dart probe \\
    --state-dir /tmp/dune-b --hostname demo-b --auth-key tskey-auth-... \\
    --node 100.x.y.z

  dart run --enable-experiment=native-assets bin/demo_node.dart pair \\
    --auth-key tskey-auth-... --control-url http://localhost:8080

Commands:
  serve   Join, start HTTP/TCP/UDP demo services, print READY, stay alive.
          By default, stays alive until SIGINT/SIGTERM.
          With --stdin-control, stdin accepts: PROBE <ip>, STOP, and EOF stops.
  probe   Join, run DemoCore.probeNode(node), print result, exit nonzero on fail.
  pair    Spawn two serve processes locally and probe both directions.

Common options:
  --state-dir DIR
  --hostname NAME
  --auth-key KEY
  --control-url URL
  --stdin-control
  --verbose
  --json

Pair options:
  --state-root DIR
  --hostname-a NAME
  --hostname-b NAME
  --timeout-seconds N
  --keep-alive
''');
}
