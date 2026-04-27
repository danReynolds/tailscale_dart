import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:demo_core/demo_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _resultPrefix = 'DUNE_SMOKE_RESULT ';
const _defaultTimeout = Duration(seconds: 120);

const _controlUrl = String.fromEnvironment('DUNE_SMOKE_CONTROL_URL');
const _authKey = String.fromEnvironment('DUNE_SMOKE_AUTH_KEY');
const _targetIp = String.fromEnvironment('DUNE_SMOKE_TARGET_IP');
const _hostname = String.fromEnvironment(
  'DUNE_SMOKE_HOSTNAME',
  defaultValue: 'dune-smoke-flutter',
);
const _stateSuffix = String.fromEnvironment(
  'DUNE_SMOKE_STATE_SUFFIX',
  defaultValue: 'default',
);

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
    try {
      _requireConfig('DUNE_SMOKE_CONTROL_URL', _controlUrl);
      _requireConfig('DUNE_SMOKE_AUTH_KEY', _authKey);
      _requireConfig('DUNE_SMOKE_TARGET_IP', _targetIp);

      final stateDir = await _stateDir();
      _event('state-dir $stateDir');
      final running = _demo.onStateChange.firstWhere(
        (state) => state == NodeState.running,
      );
      final status = await _demo.up(
        stateDir: stateDir,
        hostname: _hostname,
        authKey: _authKey,
        controlUrl: Uri.parse(_controlUrl),
        logLevel: TailscaleLogLevel.error,
      );
      if (!status.isRunning) {
        await running.timeout(_defaultTimeout);
      }

      final finalStatus = await _demo.status();
      final services = await _demo.startServices();
      final nodes = await _demo.nodes();
      final report = await _demo.probeNode(
        _targetIp,
        timeout: const Duration(seconds: 20),
      );

      _finish(
        SmokeResult(
          ok: _requiredSmokeProbesOk(report),
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          hostname: _hostname,
          platform: Platform.operatingSystem,
          localIp: finalStatus.ipv4,
          targetIp: _targetIp,
          services: services,
          nodesSeen: nodes.length,
          report: report,
          events: List.unmodifiable(_events),
        ),
      );
    } catch (error, stackTrace) {
      _event('failure $error');
      _finish(
        SmokeResult(
          ok: false,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          hostname: _hostname,
          platform: Platform.operatingSystem,
          localIp: null,
          targetIp: _targetIp,
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

  void _finish(SmokeResult result) {
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

  Future<String> _stateDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'dune_smoke', _stateSuffix);
    } catch (_) {
      return p.join(
        Directory.systemTemp.path,
        'dune_smoke_${Platform.operatingSystem}_$_stateSuffix',
      );
    }
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
                  _Chip(label: 'host', value: _hostname),
                  _Chip(label: 'target', value: _targetIp),
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
  return report.results
      .where((result) => required.contains(result.kind))
      .every((result) => result.ok);
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
          },
    'nodesSeen': nodesSeen,
    'report': report == null
        ? null
        : {
            'nodeIp': report!.nodeIp,
            'ok': report!.ok,
            'requiredOk': ok,
            'requiredKinds': [
              'whois',
              'httpGet',
              'httpPost',
              'tcpEcho',
              'udpEcho',
            ],
            'results': [
              for (final result in report!.results)
                {
                  'kind': result.kind.name,
                  'ok': result.ok,
                  'durationMs': result.duration.inMilliseconds,
                  'message': _shorten(result.message),
                },
            ],
          },
    'error': error,
    'stackTrace': stackTrace == null ? null : _shorten(stackTrace!, 600),
    'eventCount': events.length,
  };
}

void _requireConfig(String name, String value) {
  if (value.trim().isEmpty) {
    throw StateError('$name is required');
  }
}

void _emitResult(SmokeResult result) {
  // The matrix runner parses this exact line from `flutter run` logs.
  // ignore: avoid_print
  print('$_resultPrefix${jsonEncode(result.toJson())}');
}

String _shorten(String value, [int maxLength = 240]) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}...';
}
