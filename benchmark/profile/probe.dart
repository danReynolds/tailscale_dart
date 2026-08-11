// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tailscale/tailscale.dart';

import 'test_custody_adapter.dart';

const _schema = 1;
const _eventLoopTick = Duration(milliseconds: 1);

Future<void> main() async {
  final mode = Platform.environment['PERF_MODE'] ?? 'ephemeral';
  if (mode == 'build-warmup') {
    _emit(<String, Object?>{'kind': 'ready'});
    return;
  }

  try {
    final options = _ProbeOptions.fromEnvironment(mode);
    installE2ETestKeybay(options.stateDir);
    await _run(options);
    _emit(<String, Object?>{'kind': 'complete'});
    await stdout.flush();
    exit(0);
  } catch (error, stackTrace) {
    stderr.writeln('release-profile probe failed: $error');
    stderr.writeln(stackTrace);
    _emit(<String, Object?>{'kind': 'error', 'message': error.toString()});
    await stdout.flush();
    await stderr.flush();
    exit(1);
  }
}

Future<void> _run(_ProbeOptions options) async {
  final initWatch = Stopwatch()..start();
  _initCompat(stateDir: options.stateDir, appId: options.appId);
  initWatch.stop();
  _emitTiming('lifecycle.init', <_Timing>[
    _Timing(
      wallUs: initWatch.elapsedMicroseconds,
      eventLoopLagUs: initWatch.elapsedMicroseconds,
    ),
  ]);
  _emitRss('rss.after_init');

  final tsnet = Tailscale.instance;
  switch (options.mode) {
    case 'ephemeral':
      await _runEphemeral(tsnet, options);
    case 'persistent-enroll':
      await _runPersistentEnroll(tsnet, options);
    case 'persistent-restart':
      await _runPersistentRestart(tsnet, options);
    default:
      throw ArgumentError.value(options.mode, 'PERF_MODE', 'unsupported mode');
  }
}

// Tailscale 0.8.0 predates the required appId. Function.apply keeps the probe's
// measured operations identical while isolating that one initialization-shape
// difference at the compatibility boundary.
void _initCompat({required String stateDir, required String appId}) {
  final init = Tailscale.init;
  try {
    Function.apply(init, const <Object?>[], <Symbol, Object?>{
      #stateDir: stateDir,
      #appId: appId,
    });
  } on NoSuchMethodError {
    Function.apply(init, const <Object?>[], <Symbol, Object?>{
      #stateDir: stateDir,
    });
  }
}

Future<void> _runEphemeral(Tailscale tsnet, _ProbeOptions options) async {
  await _measureRepeated('lifecycle.up.ephemeral', 1, () async {
    await _upAndAwaitRunning(
      tsnet,
      () => tsnet.up(
        hostname: options.hostname,
        authKey: options.authKey,
        ephemeral: true,
        controlUrl: options.controlUrl,
      ),
    );
  }, advisoryOnly: true);

  final status = await tsnet.status();
  if (status.state != NodeState.running || status.ipv4 == null) {
    throw StateError('ephemeral up did not produce a running node with IPv4');
  }
  _emit(<String, Object?>{
    'kind': 'fact',
    'name': 'ipv4',
    'value': status.ipv4,
  });
  _emitRss('rss.after_up');

  await _awaitPeerVisible(tsnet, options.peerIp!);

  await _measureRepeated('control.status', options.iterations, () async {
    final value = await tsnet.status();
    if (value.state != NodeState.running) {
      throw StateError('status returned ${value.state}');
    }
  });
  await _measureRepeated('control.nodes', options.iterations, () async {
    final nodes = await tsnet.nodes();
    if (!nodes.any((node) => node.ipv4 == options.peerIp)) {
      throw StateError('nodes did not contain benchmark peer');
    }
  });
  await _measureRepeated('control.whois', options.iterations, () async {
    final identity = await tsnet.whois(options.peerIp!);
    if (identity == null || identity.tailscaleIPs.isEmpty) {
      throw StateError('whois did not resolve benchmark peer');
    }
  });

  await _measureRepeated('http.first_path_get', 1, () async {
    await _httpRoundTrip(tsnet, options);
  }, advisoryOnly: true);
  await _measureRepeated('http.steady_get', options.iterations, () async {
    await _httpRoundTrip(tsnet, options);
  });

  await _measureRepeated('tcp.first_round_trip', 1, () async {
    await _tcpRoundTrip(tsnet, options.peerIp!, const <int>[1, 3, 3, 7]);
  });
  await _measureRepeated('tcp.steady_round_trip', options.iterations, () async {
    await _tcpRoundTrip(tsnet, options.peerIp!, const <int>[1, 3, 3, 7]);
  });

  final bulkPayload = Uint8List(1 << 20);
  for (var i = 0; i < bulkPayload.length; i++) {
    bulkPayload[i] = (i * 37 + 11) & 0xff;
  }
  final bulkTimings = <_Timing>[];
  final bulkThroughput = <double>[];
  for (var i = 0; i < options.bulkIterations; i++) {
    final timing = await _measureAsync(
      () => _tcpRoundTrip(tsnet, options.peerIp!, bulkPayload),
    );
    bulkTimings.add(timing);
    bulkThroughput.add(
      (2.0 * bulkPayload.length / (1 << 20)) /
          (timing.wallUs / Duration.microsecondsPerSecond),
    );
  }
  _emitTiming('tcp.bulk_1mib_round_trip', bulkTimings);
  _emitMetric(
    'tcp.bulk_1mib_throughput',
    unit: 'mib_per_second',
    samples: bulkThroughput,
    higherIsBetter: true,
  );

  late final TailscaleDatagramBinding udp;
  await _measureRepeated('udp.bind', 1, () async {
    udp = await tsnet.udp.bind(port: 0).timeout(const Duration(seconds: 30));
  });
  final datagrams = StreamIterator(udp.datagrams);
  try {
    await _measureRepeated('udp.first_round_trip', 1, () async {
      await _udpRoundTrip(udp, datagrams, options.peerIp!);
    });
    await _measureRepeated(
      'udp.steady_round_trip',
      options.iterations,
      () async {
        await _udpRoundTrip(udp, datagrams, options.peerIp!);
      },
    );
  } finally {
    await datagrams.cancel();
    await udp.close();
  }

  _emitRss('rss.after_data_plane');
  await _measureRepeated('lifecycle.down.ephemeral', 1, tsnet.down);
  _emitRss('rss.after_down');
}

Future<void> _runPersistentEnroll(
  Tailscale tsnet,
  _ProbeOptions options,
) async {
  await _measureRepeated('lifecycle.up.persistent_enroll', 1, () async {
    await _upAndAwaitRunning(
      tsnet,
      () => tsnet.up(
        hostname: options.hostname,
        authKey: options.authKey,
        controlUrl: options.controlUrl,
      ),
    );
  }, advisoryOnly: true);
  final status = await tsnet.status();
  if (status.state != NodeState.running || status.ipv4 == null) {
    throw StateError('persistent enrollment did not reach running');
  }
  _emit(<String, Object?>{
    'kind': 'fact',
    'name': 'ipv4',
    'value': status.ipv4,
  });
  _emitRss('rss.after_persistent_enroll');
  await _measureRepeated('lifecycle.down.persistent', 1, tsnet.down);
}

Future<void> _runPersistentRestart(
  Tailscale tsnet,
  _ProbeOptions options,
) async {
  await _measureRepeated('lifecycle.up.persistent_restart', 1, () async {
    await _upAndAwaitRunning(
      tsnet,
      () =>
          tsnet.up(hostname: options.hostname, controlUrl: options.controlUrl),
    );
  });
  final status = await tsnet.status();
  if (status.state != NodeState.running || status.ipv4 == null) {
    throw StateError('persistent restart did not reach running');
  }
  if (options.expectedIpv4 != null && status.ipv4 != options.expectedIpv4) {
    throw StateError(
      'persistent restart changed IPv4 from '
      '${options.expectedIpv4} to ${status.ipv4}',
    );
  }
  await _measureRepeated(
    'control.status.after_restart',
    options.iterations,
    () async {
      final value = await tsnet.status();
      if (value.state != NodeState.running) {
        throw StateError('status after restart returned ${value.state}');
      }
    },
  );
  await _measureRepeated(
    'control.nodes.after_restart',
    options.iterations,
    () async {
      await tsnet.nodes();
    },
  );
  _emitRss('rss.after_persistent_restart');
  await _measureRepeated('lifecycle.logout.persistent', 1, tsnet.logout);
  _emitRss('rss.after_logout');
}

Future<void> _upAndAwaitRunning(
  Tailscale tsnet,
  Future<void> Function() start,
) async {
  final running = tsnet.onStateChange.firstWhere(
    (state) => state == NodeState.running,
  );
  await start().timeout(const Duration(seconds: 60));
  if ((await tsnet.status()).state != NodeState.running) {
    await running.timeout(const Duration(seconds: 60));
  }
}

Future<void> _awaitPeerVisible(Tailscale tsnet, String peerIp) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    if (await tsnet.whois(peerIp) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('benchmark peer $peerIp did not enter the netmap');
}

Future<void> _httpRoundTrip(Tailscale tsnet, _ProbeOptions options) async {
  final response = await tsnet.http.client
      .get(Uri.parse('http://${options.peerIp}/profile'))
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200 || response.body != options.peerResponse) {
    throw StateError(
      'HTTP validation failed: ${response.statusCode} ${response.body}',
    );
  }
}

Future<void> _tcpRoundTrip(
  Tailscale tsnet,
  String peerIp,
  List<int> payload,
) async {
  final connection = await tsnet.tcp
      .dial(peerIp, 7000, timeout: const Duration(seconds: 30))
      .timeout(const Duration(seconds: 30));
  try {
    final writeDone = () async {
      await connection.output.write(payload);
      await connection.output.close();
    }();
    final received = BytesBuilder(copy: false);
    await for (final chunk in connection.input.timeout(
      const Duration(seconds: 60),
      onTimeout: (sink) => sink.close(),
    )) {
      received.add(chunk);
      if (received.length >= payload.length) break;
    }
    await writeDone;
    final bytes = received.takeBytes();
    if (bytes.length != payload.length) {
      throw StateError(
        'TCP echo length ${bytes.length}; expected ${payload.length}',
      );
    }
    for (final index in <int>[0, payload.length ~/ 2, payload.length - 1]) {
      if (bytes[index] != payload[index]) {
        throw StateError('TCP echo mismatch at byte $index');
      }
    }
  } finally {
    await connection.close();
  }
}

Future<void> _udpRoundTrip(
  TailscaleDatagramBinding binding,
  StreamIterator<TailscaleDatagram> datagrams,
  String peerIp,
) async {
  final payload = Uint8List.fromList(
    List<int>.generate(128, (index) => (index * 19 + 5) & 0xff),
  );
  final received = datagrams.moveNext().timeout(const Duration(seconds: 15));
  await Future<void>.delayed(Duration.zero);
  await binding.send(
    payload,
    to: TailscaleEndpoint(address: peerIp, port: 7001),
  );
  if (!await received) throw StateError('UDP echo stream closed');
  final echoed = datagrams.current;
  if (echoed.remote.address != peerIp ||
      !_bytesEqual(echoed.payload, payload)) {
    throw StateError('UDP echo validation failed');
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Future<void> _measureRepeated(
  String scenario,
  int count,
  Future<void> Function() operation, {
  bool advisoryOnly = false,
}) async {
  final timings = <_Timing>[];
  for (var i = 0; i < count; i++) {
    timings.add(await _measureAsync(operation));
  }
  _emitTiming(scenario, timings, advisoryOnly: advisoryOnly);
}

Future<_Timing> _measureAsync(Future<void> Function() operation) async {
  final lagWatch = Stopwatch()..start();
  var previousTickUs = lagWatch.elapsedMicroseconds;
  var maxLagUs = 0;
  final ticker = Timer.periodic(_eventLoopTick, (_) {
    final nowUs = lagWatch.elapsedMicroseconds;
    final lagUs = math.max(
      0,
      nowUs - previousTickUs - _eventLoopTick.inMicroseconds,
    );
    maxLagUs = math.max(maxLagUs, lagUs);
    previousTickUs = nowUs;
  });
  final wallWatch = Stopwatch()..start();
  try {
    await operation();
  } finally {
    wallWatch.stop();
    await Future<void>.delayed(Duration.zero);
    ticker.cancel();
    lagWatch.stop();
  }
  return _Timing(
    wallUs: wallWatch.elapsedMicroseconds,
    eventLoopLagUs: maxLagUs,
  );
}

void _emitTiming(
  String scenario,
  List<_Timing> timings, {
  bool advisoryOnly = false,
}) {
  _emitMetric(
    scenario,
    unit: 'microseconds',
    samples: <num>[for (final timing in timings) timing.wallUs],
    advisoryOnly: advisoryOnly,
  );
  _emitMetric(
    '$scenario.event_loop_lag',
    unit: 'microseconds',
    samples: <num>[for (final timing in timings) timing.eventLoopLagUs],
    advisoryOnly: true,
  );
}

void _emitRss(String scenario) {
  _emitMetric(
    scenario,
    unit: 'bytes',
    samples: <num>[ProcessInfo.currentRss],
    advisoryOnly: true,
  );
}

void _emitMetric(
  String scenario, {
  required String unit,
  required List<num> samples,
  bool higherIsBetter = false,
  bool advisoryOnly = false,
}) {
  _emit(<String, Object?>{
    'kind': 'metric',
    'scenario': scenario,
    'unit': unit,
    'higherIsBetter': higherIsBetter,
    'advisoryOnly': advisoryOnly,
    'samples': samples,
  });
}

void _emit(Map<String, Object?> payload) {
  stdout.writeln(
    'PERF_JSON ${jsonEncode(<String, Object?>{'schema': _schema, ...payload})}',
  );
}

final class _Timing {
  const _Timing({required this.wallUs, required this.eventLoopLagUs});

  final int wallUs;
  final int eventLoopLagUs;
}

final class _ProbeOptions {
  const _ProbeOptions({
    required this.mode,
    required this.stateDir,
    required this.appId,
    required this.hostname,
    required this.controlUrl,
    required this.authKey,
    required this.peerIp,
    required this.peerResponse,
    required this.expectedIpv4,
    required this.iterations,
    required this.bulkIterations,
  });

  factory _ProbeOptions.fromEnvironment(String mode) {
    String required(String name) {
      final value = Platform.environment[name];
      if (value == null || value.isEmpty) {
        throw StateError('$name is required');
      }
      return value;
    }

    final peerIp = Platform.environment['PERF_PEER_IP'];
    if (mode == 'ephemeral' && (peerIp == null || peerIp.isEmpty)) {
      throw StateError('PERF_PEER_IP is required in ephemeral mode');
    }
    final authKey = Platform.environment['PERF_AUTH_KEY'];
    if (mode != 'persistent-restart' && (authKey == null || authKey.isEmpty)) {
      throw StateError('PERF_AUTH_KEY is required in $mode mode');
    }

    return _ProbeOptions(
      mode: mode,
      stateDir: required('PERF_STATE_DIR'),
      appId: required('PERF_APP_ID'),
      hostname: required('PERF_HOSTNAME'),
      controlUrl: Uri.parse(required('PERF_CONTROL_URL')),
      authKey: authKey,
      peerIp: peerIp,
      peerResponse: Platform.environment['PERF_PEER_RESPONSE'] ?? 'perf-peer',
      expectedIpv4: Platform.environment['PERF_EXPECTED_IPV4'],
      iterations: int.parse(Platform.environment['PERF_ITERATIONS'] ?? '20'),
      bulkIterations: int.parse(
        Platform.environment['PERF_BULK_ITERATIONS'] ?? '3',
      ),
    );
  }

  final String mode;
  final String stateDir;
  final String appId;
  final String hostname;
  final Uri controlUrl;
  final String? authKey;
  final String? peerIp;
  final String peerResponse;
  final String? expectedIpv4;
  final int iterations;
  final int bulkIterations;
}
