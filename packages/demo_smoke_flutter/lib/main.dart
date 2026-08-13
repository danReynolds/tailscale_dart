import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:demo_core/demo_core.dart';
import 'package:dune_smoke_flutter/src/runner_client.dart';
import 'package:dune_smoke_flutter/src/native_tsnet_profile.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _resultPrefix = 'DUNE_SMOKE_RESULT ';
const _defaultTimeout = Duration(seconds: 120);
const _speedRunsPerDirection = 3;
const _lanRunsPerDirection = 1;

// Compile-time only: where to fetch run-time config from. Stable across
// matrix runs on the same machine + target, so dart-defines don't change
// and Flutter doesn't have to rebuild between repeat runs.
const _runnerUrl = String.fromEnvironment(
  'DUNE_SMOKE_RUNNER_URL',
  defaultValue: 'http://localhost:18099',
);
const _session = String.fromEnvironment(
  'DUNE_SMOKE_SESSION',
  defaultValue: 'default',
);
const _runnerToken = String.fromEnvironment('DUNE_SMOKE_RUNNER_TOKEN');

void main() {
  runApp(const SmokeApp());
}

class SmokeApp extends StatelessWidget {
  const SmokeApp({super.key, this.autoStart = true});

  final bool autoStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dune Smoke',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xff65ffaf),
          secondary: Color(0xff46d9ff),
          surface: Color(0xff071612),
          error: Color(0xffff5b74),
        ),
        scaffoldBackgroundColor: const Color(0xff020706),
        fontFamily: 'monospace',
        useMaterial3: true,
      ),
      home: SmokeHome(autoStart: autoStart),
    );
  }
}

class SmokeHome extends StatefulWidget {
  const SmokeHome({super.key, required this.autoStart});

  final bool autoStart;

  @override
  State<SmokeHome> createState() => _SmokeHomeState();
}

class _SmokeHomeState extends State<SmokeHome> {
  final _demo = DemoCore();
  final _events = <String>[];
  final _subscriptions = <StreamSubscription<Object?>>[];

  bool _running = false;
  SmokeResult? _result;
  SmokeRunnerConfig? _config;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _demo.onStateChange.listen((state) {
          _event('state ${state.name}');
        }),
      )
      ..add(
        _demo.onError.listen((error) {
          _event('runtime-error ${error.message}');
        }),
      );
    if (widget.autoStart) {
      unawaited(_run());
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _result = null;
      _events.clear();
    });

    final startedAt = DateTime.now().toUtc();
    SmokeRunnerConfig? config;
    try {
      _event('fetching config from $_runnerUrl session=$_session');
      config = await fetchSmokeConfig(
        runnerUrl: Uri.parse(_runnerUrl),
        session: _session,
        token: _runnerToken,
        timeout: _defaultTimeout,
      );
      if (mounted) setState(() => _config = config);
      _event('config target=${config.targetIp} host=${config.hostname}');

      final stateDir = await _stateDir(config.stateSuffix);
      _event('state-dir $stateDir');
      final running = _demo.onStateChange.firstWhere(
        (state) => state == NodeState.running,
      );
      final status = await _demo.up(
        stateDir: stateDir,
        appId: 'dev.tailscale.dart.demo.smoke',
        hostname: config.hostname,
        authKey: config.authKey,
        ephemeral: true,
        controlUrl: Uri.parse(config.controlUrl),
        logLevel: TailscaleLogLevel.error,
      );
      if (!status.isRunning) {
        await running.timeout(_defaultTimeout);
      }

      final finalStatus = await _demo.status();
      final services = await _demo.startServices();
      final nodes = await _demo.nodes();
      final report = await _demo.probeNode(
        config.targetIp,
        timeout: const Duration(seconds: 20),
      );
      final profileTargetIp = config.targetIp;
      final firstCycleOk = _requiredSmokeProbesOk(report);
      final profileReports = <DemoProbeReport>[];
      final speedTests = <DemoSpeedTestResult>[];
      final nativeTsnetSpeedTests = <DemoSpeedTestResult>[];
      final lanSpeedTests = <SpeedTestResult>[];
      String? profileError;
      if (config.profileSamples > 0) {
        try {
          for (var sample = 1; sample <= config.profileSamples; sample++) {
            _event('profile: API sample $sample/${config.profileSamples}');
            profileReports.add(
              await _demo.probeNode(
                config.targetIp,
                timeout: const Duration(seconds: 30),
              ),
            );
          }
          for (var run = 1; run <= _speedRunsPerDirection; run++) {
            final directions = run.isOdd
                ? SpeedTestDirection.values
                : SpeedTestDirection.values.reversed;
            for (final direction in directions) {
              Future<void> dartApi() async {
                _event(
                  'profile: Dart TCP ${direction.name} '
                  '$run/$_speedRunsPerDirection',
                );
                speedTests.add(
                  await _demo.profileNode(
                    profileTargetIp,
                    direction: direction,
                  ),
                );
              }

              Future<void> nativeTsnet() async {
                _event(
                  'profile: native tsnet ${direction.name} '
                  '$run/$_speedRunsPerDirection',
                );
                nativeTsnetSpeedTests.add(
                  await _profileNativeTsnet(
                    profileTargetIp,
                    direction: direction,
                  ),
                );
              }

              // Alternate pair order so first/second-run thermal or network
              // drift is not assigned systematically to either lane.
              if (run.isOdd) {
                await dartApi();
                await nativeTsnet();
              } else {
                await nativeTsnet();
                await dartApi();
              }
            }
          }
          final lanHost = config.lanProfileHost;
          final lanPort = config.lanProfilePort;
          if (lanHost == null || lanPort == null) {
            throw StateError('runner did not provide the ordinary-LAN control');
          }
          for (var run = 1; run <= _lanRunsPerDirection; run++) {
            final directions = run.isOdd
                ? SpeedTestDirection.values
                : SpeedTestDirection.values.reversed;
            for (final direction in directions) {
              _event(
                'profile: LAN ${direction.name} '
                '$run/$_lanRunsPerDirection',
              );
              lanSpeedTests.add(
                await _profileLan(lanHost, lanPort, direction: direction),
              );
            }
          }
        } catch (error) {
          profileError = error.toString();
          _event('profile: error $error');
        }
      }
      final profileStatus = _profileStatus(
        requestedSamples: config.profileSamples,
        reports: profileReports,
        speedTests: speedTests,
        nativeTsnetSpeedTests: nativeTsnetSpeedTests,
        lanSpeedTests: lanSpeedTests,
        error: profileError,
      );

      // Restart cycle: the runtime lifecycle receipt. A second Server start in
      // the same app process proves stop/start under the platform's real app
      // sandbox (on Android: the zygote seccomp policy) and that the fresh
      // generation still moves traffic. The reusable auth key re-enrolls the
      // ephemeral node.
      _event('restart: down');
      await _demo.down();
      final restartRunning = _demo.onStateChange.firstWhere(
        (state) => state == NodeState.running,
      );
      _event('restart: up');
      final restartStatus = await _demo.up(
        stateDir: stateDir,
        appId: 'dev.tailscale.dart.demo.smoke',
        hostname: config.hostname,
        authKey: config.authKey,
        ephemeral: true,
        controlUrl: Uri.parse(config.controlUrl),
        logLevel: TailscaleLogLevel.error,
      );
      if (!restartStatus.isRunning) {
        await restartRunning.timeout(_defaultTimeout);
      }
      final restartReport = await _demo.probeNode(
        config.targetIp,
        timeout: const Duration(seconds: 20),
      );
      final restartOk = _requiredSmokeProbesOk(restartReport);
      _event('restart: down (final)');
      await _demo.down();

      await _finish(
        SmokeResult(
          ok: firstCycleOk && restartOk,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          hostname: config.hostname,
          platform: Platform.operatingSystem,
          localIp: finalStatus.ipv4,
          targetIp: config.targetIp,
          services: services,
          nodesSeen: nodes.length,
          report: report,
          profileReports: profileReports,
          profileRequested: config.profileSamples > 0,
          profileContext: config.profileContext,
          profileStatus: profileStatus,
          profileError: profileError,
          speedTests: speedTests,
          nativeTsnetSpeedTests: nativeTsnetSpeedTests,
          lanSpeedTests: lanSpeedTests,
          restartReport: restartReport,
          restartOk: restartOk,
          events: List.unmodifiable(_events),
        ),
      );
    } catch (error, stackTrace) {
      _event('failure $error');
      await _finish(
        SmokeResult(
          ok: false,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          hostname: config?.hostname ?? 'dune-smoke-$_session',
          platform: Platform.operatingSystem,
          localIp: null,
          targetIp: config?.targetIp ?? '',
          services: null,
          nodesSeen: 0,
          report: null,
          error: error.toString(),
          stackTrace: stackTrace.toString(),
          events: List.unmodifiable(_events),
        ),
      );
    }
  }

  Future<void> _finish(SmokeResult result) async {
    await _postResult(result);
    _emitResult(result);
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  void _event(String message) {
    if (!mounted) return;
    setState(() {
      _events.add('${DateTime.now().toUtc().toIso8601String()} $message');
      if (_events.length > 100) _events.removeAt(0);
    });
  }

  Future<String> _stateDir(String stateSuffix) async {
    try {
      final temporary = await getTemporaryDirectory();
      return p.join(temporary.path, 'dune_smoke', stateSuffix);
    } catch (_) {
      return p.join(
        Directory.systemTemp.path,
        'dune_smoke_${Platform.operatingSystem}_$stateSuffix',
      );
    }
  }

  Future<SpeedTestResult> _profileLan(
    String host,
    int port, {
    required SpeedTestDirection direction,
  }) async {
    final socket = await Socket.connect(host, port, timeout: _defaultTimeout);
    return runSpeedTestClient(
      SpeedTestConnection.bufferedSink(
        input: socket,
        add: socket.add,
        flush: socket.flush,
        close: () async => socket.destroy(),
      ),
      direction: direction,
      config: ordinaryLanControlConfig,
      timeout: _defaultTimeout,
    );
  }

  Future<DemoSpeedTestResult> _profileNativeTsnet(
    String nodeIp, {
    required SpeedTestDirection direction,
  }) async {
    final pathBefore = await _demo.pingNode(nodeIp, timeout: _defaultTimeout);
    final transfer = await runNativeTsnetProfile(
      host: nodeIp,
      port: profileSpeedTestPort,
      direction: direction,
      timeout: _defaultTimeout,
    );
    final pathAfter = await _demo.pingNode(nodeIp, timeout: _defaultTimeout);
    return DemoSpeedTestResult(
      transfer: transfer,
      pathBefore: pathBefore,
      pathAfter: pathAfter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '[SMOKE] Dune Flutter Probe',
                style: TextStyle(
                  color: Color(0xff65ffaf),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 16),
              _StatusCard(running: _running, result: result),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Chip(label: 'platform', value: Platform.operatingSystem),
                  _Chip(label: 'session', value: _session),
                  if (_config != null)
                    _Chip(label: 'target', value: _config!.targetIp),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _running ? null : _run,
                child: const Text('Run Smoke Probe'),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xff071612),
                    border: Border.all(color: const Color(0xff164f3f)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _events.isEmpty ? 'waiting...' : _events.join('\n'),
                      style: const TextStyle(
                        color: Color(0xffa7c8bd),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.running, required this.result});

  final bool running;
  final SmokeResult? result;

  @override
  Widget build(BuildContext context) {
    final color = running
        ? const Color(0xffffd166)
        : result == null
        ? const Color(0xff46d9ff)
        : result!.ok
        ? const Color(0xff65ffaf)
        : const Color(0xffff5b74);
    final label = running
        ? 'RUNNING'
        : result == null
        ? 'READY'
        : result!.ok
        ? 'PASS'
        : 'FAIL';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.72)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 28,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff164f3f)),
      ),
      child: Text(
        '$label=$value',
        style: const TextStyle(color: Color(0xff46d9ff), fontSize: 12),
      ),
    );
  }
}

bool _requiredSmokeProbesOk(DemoProbeReport report) {
  const required = {
    DemoProbeKind.whois,
    DemoProbeKind.httpGet,
    DemoProbeKind.httpPost,
    DemoProbeKind.tcpEcho,
    DemoProbeKind.udpEcho,
  };
  final results = report.results
      .where((result) => required.contains(result.kind))
      .toList(growable: false);
  return results.length == required.length &&
      results.every((result) => result.ok);
}

final class SmokeResult {
  const SmokeResult({
    required this.ok,
    required this.startedAt,
    required this.finishedAt,
    required this.hostname,
    required this.platform,
    required this.localIp,
    required this.targetIp,
    required this.services,
    required this.nodesSeen,
    required this.report,
    required this.events,
    this.profileReports = const [],
    this.profileRequested = false,
    this.profileContext = 'primary',
    this.profileStatus = 'notRun',
    this.profileError,
    this.speedTests = const [],
    this.nativeTsnetSpeedTests = const [],
    this.lanSpeedTests = const [],
    this.restartReport,
    this.restartOk = false,
    this.error,
    this.stackTrace,
  });

  final bool ok;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String hostname;
  final String platform;
  final String? localIp;
  final String targetIp;
  final DemoServices? services;
  final int nodesSeen;
  final DemoProbeReport? report;
  final List<DemoProbeReport> profileReports;
  final bool profileRequested;
  final String profileContext;
  final String profileStatus;
  final String? profileError;
  final List<DemoSpeedTestResult> speedTests;
  final List<DemoSpeedTestResult> nativeTsnetSpeedTests;
  final List<SpeedTestResult> lanSpeedTests;
  final DemoProbeReport? restartReport;
  final bool restartOk;
  final String? error;
  final String? stackTrace;
  final List<String> events;

  Map<String, Object?> toJson() => {
    'ok': ok,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'durationMs': finishedAt.difference(startedAt).inMilliseconds,
    'hostname': hostname,
    'platform': platform,
    'localIp': localIp,
    'targetIp': targetIp,
    'services': services == null
        ? null
        : {
            'localIp': services!.localIp,
            'httpTailnetPort': services!.httpTailnetPort,
            'tcpPort': services!.tcpPort,
            'udpPort': services!.udpPort,
            'speedTestPort': services!.speedTestPort,
          },
    'nodesSeen': nodesSeen,
    'report': _reportJson(report),
    'profile': !profileRequested
        ? null
        : {
            'status': profileStatus,
            'valid': profileStatus == 'complete',
            'context': profileContext,
            'error': profileError == null ? null : _shorten(profileError!),
            'sampleCount': profileReports.length,
            'reports': [
              for (final report in profileReports) _reportJson(report),
            ],
            'speedTests': [
              for (final speedTest in speedTests) _speedTestJson(speedTest),
            ],
            'nativeTsnetSpeedTests': [
              for (final speedTest in nativeTsnetSpeedTests)
                _speedTestJson(speedTest),
            ],
            'lanSpeedTests': [
              for (final speedTest in lanSpeedTests) speedTest.toJson(),
            ],
          },
    'restart': restartReport == null
        ? null
        : {'ok': restartOk, 'report': _reportJson(restartReport)},
    'error': error,
    'stackTrace': stackTrace == null ? null : _shorten(stackTrace!, 600),
    'eventCount': events.length,
  };

  static Map<String, Object?>? _reportJson(DemoProbeReport? report) {
    if (report == null) return null;
    return {
      'nodeIp': report.nodeIp,
      'ok': report.ok,
      'requiredOk': _requiredSmokeProbesOk(report),
      'requiredKinds': ['whois', 'httpGet', 'httpPost', 'tcpEcho', 'udpEcho'],
      'results': [
        for (final result in report.results)
          {
            'kind': result.kind.name,
            'ok': result.ok,
            'durationMs': result.duration.inMilliseconds,
            'durationUs': result.duration.inMicroseconds,
            'message': _shorten(result.message),
            if (result.networkLatency != null)
              'networkLatencyUs': result.networkLatency!.inMicroseconds,
            if (result.networkPath != null) 'networkPath': result.networkPath,
          },
      ],
    };
  }

  static Map<String, Object?> _speedTestJson(DemoSpeedTestResult value) => {
    'comparisonEligible': value.comparisonEligible,
    'ineligibleReason': value.ineligibleReason,
    'pathBefore': _pathJson(value.pathBefore),
    'pathAfter': _pathJson(value.pathAfter),
    'result': value.transfer.toJson(),
  };

  static Map<String, Object?> _pathJson(DemoProbeResult value) => {
    'ok': value.ok,
    'durationUs': value.duration.inMicroseconds,
    if (value.networkLatency != null)
      'networkLatencyUs': value.networkLatency!.inMicroseconds,
    if (value.networkPath != null) 'networkPath': value.networkPath,
  };
}

String _profileStatus({
  required int requestedSamples,
  required List<DemoProbeReport> reports,
  required List<DemoSpeedTestResult> speedTests,
  required List<DemoSpeedTestResult> nativeTsnetSpeedTests,
  required List<SpeedTestResult> lanSpeedTests,
  required String? error,
}) {
  if (requestedSamples == 0) return 'notRun';
  if (error != null) return 'error';
  if (reports.length != requestedSamples ||
      !reports.every(_requiredSmokeProbesOk)) {
    return 'invalid';
  }
  if (speedTests.length !=
          _speedRunsPerDirection * SpeedTestDirection.values.length ||
      !speedTests.every((value) => value.comparisonEligible)) {
    return 'invalid';
  }
  if (nativeTsnetSpeedTests.length !=
          _speedRunsPerDirection * SpeedTestDirection.values.length ||
      !nativeTsnetSpeedTests.every((value) => value.comparisonEligible)) {
    return 'invalid';
  }
  if (lanSpeedTests.length !=
          _lanRunsPerDirection * SpeedTestDirection.values.length ||
      !lanSpeedTests.every((value) => value.valid)) {
    return 'invalid';
  }
  return 'complete';
}

Future<void> _postResult(SmokeResult result) async {
  try {
    await postSmokeResult(
      runnerUrl: Uri.parse(_runnerUrl),
      session: _session,
      token: _runnerToken,
      result: result.toJson(),
    );
  } catch (_) {
    // Result is also emitted to stdout, so don't fail the run if POST fails.
  }
}

void _emitResult(SmokeResult result) {
  // The matrix runner accepts this stdout line as a fallback if /result POST
  // fails to land. Keep emitting it for diagnostic visibility too.
  // ignore: avoid_print
  print('$_resultPrefix${jsonEncode(result.toJson())}');
}

String _shorten(String value, [int maxLength = 240]) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}...';
}
