// ignore_for_file: avoid_print
/// Benchmark: POSIX fd transport data-plane throughput and write latency.
///
/// This intentionally targets the stable fd transport facade used underneath
/// TCP, UDP, and HTTP rather than reactor-specific debug hooks. That makes the
/// benchmark runnable against both the pre-reactor implementation and the
/// shared-reactor implementation for before/after comparisons.
///
/// Usage:
///   dart run --enable-experiment=native-assets benchmark/fd_transport.dart
///
/// Useful comparison run:
///   dart run --enable-experiment=native-assets benchmark/fd_transport.dart \
///     --pairs=1,10,50,100 --payload-mib=4 --latency-writes=200 --json
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _afUnix = 1;
const _sockStream = 1;
const _defaultChunkKiB = 64;
const _defaultPayloadMiB = 4;
const _defaultLatencyWrites = 200;
const _defaultLatencyBytes = 64;
const _defaultChurnCount = 100;
const _defaultHttpRequests = 100;
const _benchmarkTimeout = Duration(minutes: 3);

Future<void> main(List<String> args) async {
  if (Platform.isWindows) {
    print('POSIX fd transport benchmarks are not supported on Windows.');
    exitCode = 1;
    return;
  }

  final options = _Options.parse(args);
  ensurePosixFdTransportAvailable();

  print('');
  print('=== tailscale POSIX fd transport benchmark ===');
  print('');
  print('pairs: ${options.pairs.join(', ')}');
  print('extra pairs: ${options.extraPairs.join(', ')}');
  print('payload per pair: ${options.payloadMiB} MiB');
  print('write chunk: ${options.chunkKiB} KiB');
  print('latency writes per pair: ${options.latencyWrites}');
  print('latency payload: ${options.latencyBytes} bytes');
  print('churn count: ${options.churnCount}');
  print('HTTP-shaped requests: ${options.httpRequests}');
  print('');

  final results = <_BenchResult>[];

  for (final pairs in options.pairs) {
    results.add(
      await _benchThroughput(
        pairs: pairs,
        payloadBytesPerPair: options.payloadMiB * 1024 * 1024,
        chunkBytes: options.chunkKiB * 1024,
      ).timeout(_benchmarkTimeout),
    );
  }

  for (final pairs in options.pairs) {
    results.add(
      await _benchWriteLatency(
        pairs: pairs,
        writesPerPair: options.latencyWrites,
        payloadBytes: options.latencyBytes,
      ).timeout(_benchmarkTimeout),
    );
  }

  results.add(
    await _benchAdoptionChurn(
      count: options.churnCount,
      payloadBytes: options.latencyBytes,
    ).timeout(_benchmarkTimeout),
  );

  for (final pairs in options.extraPairs) {
    results.add(
      await _benchFullDuplexThroughput(
        pairs: pairs,
        payloadBytesPerDirection: options.payloadMiB * 1024 * 1024,
        chunkBytes: options.chunkKiB * 1024,
      ).timeout(_benchmarkTimeout),
    );
  }

  for (final pairs in options.extraPairs) {
    results.add(
      await _benchFairnessUnderLoad(
        backgroundPairs: pairs,
        backgroundBytesPerPair: options.payloadMiB * 1024 * 1024,
        chunkBytes: options.chunkKiB * 1024,
        latencyWrites: options.latencyWrites,
        latencyBytes: options.latencyBytes,
      ).timeout(_benchmarkTimeout),
    );
  }

  results.add(
    await _benchHttpShapedRequests(
      requests: options.httpRequests,
      requestBytes: options.latencyBytes,
      responseBytes: options.chunkKiB * 1024,
    ).timeout(_benchmarkTimeout),
  );

  _printResults(results);

  if (options.emitJson) {
    print('');
    print(
      jsonEncode(<String, Object?>{
        'benchmark': 'fd_transport',
        'results': results.map((result) => result.toJson()).toList(),
      }),
    );
  }
}

Future<_BenchResult> _benchThroughput({
  required int pairs,
  required int payloadBytesPerPair,
  required int chunkBytes,
}) async {
  final rssBefore = ProcessInfo.currentRss;
  final transports = <_TransportPair>[];
  final drainFutures = <Future<int>>[];
  try {
    for (var i = 0; i < pairs; i++) {
      final pair = await _connectedPair(
        maxPendingWriteBytes: chunkBytes * 4,
        maxReadChunkSize: chunkBytes,
      );
      transports.add(pair);
      drainFutures.add(_drainUntilEof(pair.right.input));
    }

    final rssAfterAdopt = ProcessInfo.currentRss;
    final elapsed = await _measure(() async {
      await Future.wait(<Future<void>>[
        for (final pair in transports)
          _writePayload(
            pair.left,
            totalBytes: payloadBytesPerPair,
            chunkBytes: chunkBytes,
          ),
      ]);

      await Future.wait(<Future<void>>[
        for (final pair in transports) pair.left.closeWrite(),
      ]);

      final totals = await Future.wait(drainFutures);
      for (final total in totals) {
        if (total != payloadBytesPerPair) {
          throw StateError(
            'received $total bytes; expected $payloadBytesPerPair',
          );
        }
      }
    });

    final totalBytes = pairs * payloadBytesPerPair;
    return _BenchResult(
      name: 'throughput_one_way',
      scale: pairs,
      metrics: <String, num>{
        'payload_mib_per_pair': payloadBytesPerPair / (1024 * 1024),
        'chunk_kib': chunkBytes / 1024,
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'total_mib': totalBytes / (1024 * 1024),
        'mib_per_second': _mibPerSecond(totalBytes, elapsed),
        'rss_adopt_delta_mib': _bytesToMiB(rssAfterAdopt - rssBefore),
      },
    );
  } finally {
    await _closePairs(transports);
  }
}

Future<_BenchResult> _benchWriteLatency({
  required int pairs,
  required int writesPerPair,
  required int payloadBytes,
}) async {
  final transports = <_TransportPair>[];
  final drainFutures = <Future<int>>[];
  final latenciesUs = <int>[];
  try {
    for (var i = 0; i < pairs; i++) {
      final pair = await _connectedPair();
      transports.add(pair);
      drainFutures.add(_drainUntilEof(pair.right.input));
    }

    final payload = _payload(payloadBytes);
    final elapsed = await _measure(() async {
      await Future.wait(<Future<void>>[
        for (final pair in transports)
          _writeSmallPayloads(
            pair.left,
            payload: payload,
            writes: writesPerPair,
            latenciesUs: latenciesUs,
          ),
      ]);

      await Future.wait(<Future<void>>[
        for (final pair in transports) pair.left.closeWrite(),
      ]);

      final totals = await Future.wait(drainFutures);
      final expectedBytes = writesPerPair * payloadBytes;
      for (final total in totals) {
        if (total != expectedBytes) {
          throw StateError('received $total bytes; expected $expectedBytes');
        }
      }
    });

    return _BenchResult(
      name: 'write_latency',
      scale: pairs,
      metrics: <String, num>{
        'writes_per_pair': writesPerPair,
        'payload_bytes': payloadBytes,
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'writes_per_second': _perSecond(pairs * writesPerPair, elapsed),
        'p50_us': _percentile(latenciesUs, 50),
        'p95_us': _percentile(latenciesUs, 95),
        'p99_us': _percentile(latenciesUs, 99),
      },
    );
  } finally {
    await _closePairs(transports);
  }
}

Future<_BenchResult> _benchAdoptionChurn({
  required int count,
  required int payloadBytes,
}) async {
  final rssBefore = ProcessInfo.currentRss;
  final latenciesUs = <int>[];
  final payload = _payload(payloadBytes);

  final elapsed = await _measure(() async {
    for (var i = 0; i < count; i++) {
      final sw = Stopwatch()..start();
      final pair = await _connectedPair();
      sw.stop();
      latenciesUs.add(sw.elapsedMicroseconds);
      final iterator = StreamIterator(pair.right.input);
      try {
        await pair.left.write(payload);
        if (!await iterator.moveNext().timeout(const Duration(seconds: 5))) {
          throw StateError('churn pair closed before echo payload');
        }
      } finally {
        await iterator.cancel();
        await _closePairs(<_TransportPair>[pair]);
      }
    }
  });

  final rssAfter = ProcessInfo.currentRss;
  return _BenchResult(
    name: 'adoption_churn',
    scale: count,
    metrics: <String, num>{
      'count': count,
      'elapsed_ms': elapsed.inMicroseconds / 1000,
      'adoptions_per_second': _perSecond(count * 2, elapsed),
      'pair_p50_us': _percentile(latenciesUs, 50),
      'pair_p95_us': _percentile(latenciesUs, 95),
      'pair_p99_us': _percentile(latenciesUs, 99),
      'rss_delta_mib': _bytesToMiB(rssAfter - rssBefore),
    },
  );
}

Future<_BenchResult> _benchFullDuplexThroughput({
  required int pairs,
  required int payloadBytesPerDirection,
  required int chunkBytes,
}) async {
  final transports = <_TransportPair>[];
  final drains = <Future<int>>[];
  try {
    for (var i = 0; i < pairs; i++) {
      final pair = await _connectedPair(
        maxPendingWriteBytes: chunkBytes * 4,
        maxReadChunkSize: chunkBytes,
      );
      transports.add(pair);
      drains.add(_drainUntilEof(pair.left.input));
      drains.add(_drainUntilEof(pair.right.input));
    }

    final elapsed = await _measure(() async {
      await Future.wait(<Future<void>>[
        for (final pair in transports) ...<Future<void>>[
          _writePayload(
            pair.left,
            totalBytes: payloadBytesPerDirection,
            chunkBytes: chunkBytes,
          ),
          _writePayload(
            pair.right,
            totalBytes: payloadBytesPerDirection,
            chunkBytes: chunkBytes,
          ),
        ],
      ]);
      await Future.wait(<Future<void>>[
        for (final pair in transports) ...<Future<void>>[
          pair.left.closeWrite(),
          pair.right.closeWrite(),
        ],
      ]);

      final totals = await Future.wait(drains);
      for (final total in totals) {
        if (total != payloadBytesPerDirection) {
          throw StateError(
            'received $total bytes; expected $payloadBytesPerDirection',
          );
        }
      }
    });

    final totalBytes = pairs * payloadBytesPerDirection * 2;
    return _BenchResult(
      name: 'throughput_full_duplex',
      scale: pairs,
      metrics: <String, num>{
        'payload_mib_per_direction': payloadBytesPerDirection / (1024 * 1024),
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'total_mib': totalBytes / (1024 * 1024),
        'mib_per_second': _mibPerSecond(totalBytes, elapsed),
      },
    );
  } finally {
    await _closePairs(transports);
  }
}

Future<_BenchResult> _benchFairnessUnderLoad({
  required int backgroundPairs,
  required int backgroundBytesPerPair,
  required int chunkBytes,
  required int latencyWrites,
  required int latencyBytes,
}) async {
  final background = <_TransportPair>[];
  final backgroundDrains = <Future<int>>[];
  _TransportPair? latencyPair;
  final latenciesUs = <int>[];
  try {
    for (var i = 0; i < backgroundPairs; i++) {
      final pair = await _connectedPair(
        maxPendingWriteBytes: chunkBytes * 4,
        maxReadChunkSize: chunkBytes,
      );
      background.add(pair);
      backgroundDrains.add(_drainUntilEof(pair.right.input));
    }
    latencyPair = await _connectedPair();
    final latencyDrain = _drainUntilEof(latencyPair.right.input);
    final latencyPayload = _payload(latencyBytes);

    final elapsed = await _measure(() async {
      final backgroundWrites = Future.wait(<Future<void>>[
        for (final pair in background)
          _writePayload(
            pair.left,
            totalBytes: backgroundBytesPerPair,
            chunkBytes: chunkBytes,
          ).then((_) => pair.left.closeWrite()),
      ]);

      await _writeSmallPayloads(
        latencyPair!.left,
        payload: latencyPayload,
        writes: latencyWrites,
        latenciesUs: latenciesUs,
      );
      await latencyPair.left.closeWrite();

      await backgroundWrites;
      final backgroundTotals = await Future.wait(backgroundDrains);
      for (final total in backgroundTotals) {
        if (total != backgroundBytesPerPair) {
          throw StateError(
            'received $total bytes; expected $backgroundBytesPerPair',
          );
        }
      }
      final latencyTotal = await latencyDrain;
      final expectedLatencyBytes = latencyWrites * latencyBytes;
      if (latencyTotal != expectedLatencyBytes) {
        throw StateError(
          'received $latencyTotal bytes; expected $expectedLatencyBytes',
        );
      }
    });

    return _BenchResult(
      name: 'fairness_under_load',
      scale: backgroundPairs,
      metrics: <String, num>{
        'background_pairs': backgroundPairs,
        'background_mib_per_pair': backgroundBytesPerPair / (1024 * 1024),
        'latency_writes': latencyWrites,
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'p50_us': _percentile(latenciesUs, 50),
        'p95_us': _percentile(latenciesUs, 95),
        'p99_us': _percentile(latenciesUs, 99),
      },
    );
  } finally {
    await _closePairs(background);
    if (latencyPair != null) {
      await _closePairs(<_TransportPair>[latencyPair]);
    }
  }
}

Future<_BenchResult> _benchHttpShapedRequests({
  required int requests,
  required int requestBytes,
  required int responseBytes,
}) async {
  final rssBefore = ProcessInfo.currentRss;
  final latenciesUs = <int>[];
  final requestPayload = _payload(requestBytes);
  final responsePayload = _payload(responseBytes);

  final elapsed = await _measure(() async {
    for (var i = 0; i < requests; i++) {
      final requestBody = await _connectedPair();
      final responseBody = await _connectedPair();
      final sw = Stopwatch()..start();
      try {
        final serverRead = _drainUntilEof(requestBody.right.input);
        final clientRead = _drainUntilEof(responseBody.left.input);

        await Future.wait(<Future<void>>[
          requestBody.left.write(requestPayload),
          responseBody.right.write(responsePayload),
        ]);
        await Future.wait(<Future<void>>[
          requestBody.left.closeWrite(),
          responseBody.right.closeWrite(),
        ]);

        final totals = await Future.wait(<Future<int>>[serverRead, clientRead]);
        if (totals[0] != requestBytes) {
          throw StateError(
            'server read ${totals[0]} bytes; expected $requestBytes',
          );
        }
        if (totals[1] != responseBytes) {
          throw StateError(
            'client read ${totals[1]} bytes; expected $responseBytes',
          );
        }
        sw.stop();
        latenciesUs.add(sw.elapsedMicroseconds);
      } finally {
        await _closePairs(<_TransportPair>[requestBody, responseBody]);
      }
    }
  });

  final rssAfter = ProcessInfo.currentRss;
  return _BenchResult(
    name: 'http_shaped_requests',
    scale: requests,
    metrics: <String, num>{
      'requests': requests,
      'request_bytes': requestBytes,
      'response_bytes': responseBytes,
      'elapsed_ms': elapsed.inMicroseconds / 1000,
      'requests_per_second': _perSecond(requests, elapsed),
      'p50_us': _percentile(latenciesUs, 50),
      'p95_us': _percentile(latenciesUs, 95),
      'p99_us': _percentile(latenciesUs, 99),
      'rss_delta_mib': _bytesToMiB(rssAfter - rssBefore),
    },
  );
}

Future<void> _writePayload(
  PosixFdTransport transport, {
  required int totalBytes,
  required int chunkBytes,
}) async {
  final chunk = _payload(chunkBytes);
  var remaining = totalBytes;
  while (remaining > 0) {
    final n = remaining < chunk.length ? remaining : chunk.length;
    if (n == chunk.length) {
      await transport.write(chunk);
    } else {
      await transport.write(Uint8List.sublistView(chunk, 0, n));
    }
    remaining -= n;
  }
}

Future<void> _writeSmallPayloads(
  PosixFdTransport transport, {
  required Uint8List payload,
  required int writes,
  required List<int> latenciesUs,
}) async {
  for (var i = 0; i < writes; i++) {
    final sw = Stopwatch()..start();
    await transport.write(payload);
    sw.stop();
    latenciesUs.add(sw.elapsedMicroseconds);
  }
}

Future<int> _drainUntilEof(Stream<Uint8List> input) async {
  var total = 0;
  await for (final chunk in input) {
    total += chunk.length;
  }
  return total;
}

Future<Duration> _measure(Future<void> Function() fn) async {
  final sw = Stopwatch()..start();
  await fn();
  sw.stop();
  return sw.elapsed;
}

Future<_TransportPair> _connectedPair({
  int maxReadChunkSize = 64 * 1024,
  int maxPendingWriteBytes = 1024 * 1024,
}) async {
  final (:leftFd, :rightFd) = _socketPair();
  final left = await PosixFdTransport.adopt(
    leftFd,
    maxReadChunkSize: maxReadChunkSize,
    maxPendingWriteBytes: maxPendingWriteBytes,
  );
  try {
    final right = await PosixFdTransport.adopt(
      rightFd,
      maxReadChunkSize: maxReadChunkSize,
      maxPendingWriteBytes: maxPendingWriteBytes,
    );
    return _TransportPair(left, right);
  } catch (_) {
    await left.close();
    _BenchPosixBindings.instance.close(rightFd);
    rethrow;
  }
}

({int leftFd, int rightFd}) _socketPair() {
  final fds = calloc<Int32>(2);
  try {
    final result = _BenchPosixBindings.instance.socketpair(
      _afUnix,
      _sockStream,
      0,
      fds,
    );
    if (result != 0) {
      throw StateError('socketpair failed with result $result');
    }
    return (leftFd: fds[0], rightFd: fds[1]);
  } finally {
    calloc.free(fds);
  }
}

Future<void> _closePairs(List<_TransportPair> pairs) async {
  await Future.wait(<Future<void>>[
    for (final pair in pairs) ...<Future<void>>[
      pair.left.close(),
      pair.right.close(),
    ],
  ]);
}

Uint8List _payload(int bytes) {
  final payload = Uint8List(bytes);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = i & 0xff;
  }
  return payload;
}

num _percentile(List<int> values, int percentile) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  final index = ((percentile / 100) * (sorted.length - 1)).round();
  return sorted[index];
}

double _mibPerSecond(int bytes, Duration elapsed) =>
    _bytesToMiB(bytes) / _seconds(elapsed);

double _perSecond(int count, Duration elapsed) => count / _seconds(elapsed);

double _seconds(Duration elapsed) =>
    math.max(elapsed.inMicroseconds / Duration.microsecondsPerSecond, 0.000001);

double _bytesToMiB(int bytes) => bytes / (1024 * 1024);

void _printResults(List<_BenchResult> results) {
  print('name                    scale   metric');
  print(
    '----------------------  ------  --------------------------------------',
  );
  for (final result in results) {
    final metric = switch (result.name) {
      'throughput_one_way' =>
        '${_fmt(result.metrics['mib_per_second'])} MiB/s '
            '(${_fmt(result.metrics['total_mib'])} MiB in '
            '${_fmt(result.metrics['elapsed_ms'])} ms, '
            'RSS +${_fmt(result.metrics['rss_adopt_delta_mib'])} MiB)',
      'write_latency' =>
        'p50 ${_fmt(result.metrics['p50_us'])} us, '
            'p95 ${_fmt(result.metrics['p95_us'])} us, '
            'p99 ${_fmt(result.metrics['p99_us'])} us, '
            '${_fmt(result.metrics['writes_per_second'])} writes/s',
      'adoption_churn' =>
        'p50 ${_fmt(result.metrics['pair_p50_us'])} us/pair, '
            'p95 ${_fmt(result.metrics['pair_p95_us'])} us/pair, '
            '${_fmt(result.metrics['adoptions_per_second'])} fd adopts/s, '
            'RSS ${_signedFmt(result.metrics['rss_delta_mib'])} MiB',
      'throughput_full_duplex' =>
        '${_fmt(result.metrics['mib_per_second'])} MiB/s '
            '(${_fmt(result.metrics['total_mib'])} MiB in '
            '${_fmt(result.metrics['elapsed_ms'])} ms)',
      'fairness_under_load' =>
        'small-write p50 ${_fmt(result.metrics['p50_us'])} us, '
            'p95 ${_fmt(result.metrics['p95_us'])} us, '
            'p99 ${_fmt(result.metrics['p99_us'])} us',
      'http_shaped_requests' =>
        'p50 ${_fmt(result.metrics['p50_us'])} us/request, '
            'p95 ${_fmt(result.metrics['p95_us'])} us/request, '
            '${_fmt(result.metrics['requests_per_second'])} req/s, '
            'RSS ${_signedFmt(result.metrics['rss_delta_mib'])} MiB',
      _ => result.metrics.toString(),
    };
    print(
      '${result.name.padRight(22)}  ${'${result.scale}'.padLeft(6)}  $metric',
    );
  }
}

String _fmt(num? value) {
  if (value == null) return '0';
  if (value.abs() >= 100) return value.toStringAsFixed(0);
  if (value.abs() >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

String _signedFmt(num? value) {
  if (value == null) return '0';
  final formatted = _fmt(value);
  return value >= 0 ? '+$formatted' : formatted;
}

final class _Options {
  const _Options({
    required this.pairs,
    required this.extraPairs,
    required this.payloadMiB,
    required this.chunkKiB,
    required this.latencyWrites,
    required this.latencyBytes,
    required this.churnCount,
    required this.httpRequests,
    required this.emitJson,
  });

  final List<int> pairs;
  final List<int> extraPairs;
  final int payloadMiB;
  final int chunkKiB;
  final int latencyWrites;
  final int latencyBytes;
  final int churnCount;
  final int httpRequests;
  final bool emitJson;

  static _Options parse(List<String> args) {
    final values = <String, String>{};
    var emitJson = false;
    for (final arg in args) {
      if (arg == '--json') {
        emitJson = true;
        continue;
      }
      if (arg == '--help' || arg == '-h') {
        _printUsageAndExit();
      }
      final separator = arg.indexOf('=');
      if (!arg.startsWith('--') || separator < 0) {
        throw ArgumentError('unknown argument: $arg');
      }
      values[arg.substring(2, separator)] = arg.substring(separator + 1);
    }

    return _Options(
      pairs: _parsePairs(values['pairs'] ?? '1,10,50,100', 'pairs'),
      extraPairs: _parsePairs(values['extra-pairs'] ?? '1', 'extra-pairs'),
      payloadMiB: _parsePositiveInt(
        values['payload-mib'],
        _defaultPayloadMiB,
        'payload-mib',
      ),
      chunkKiB: _parsePositiveInt(
        values['chunk-kib'],
        _defaultChunkKiB,
        'chunk-kib',
      ),
      latencyWrites: _parsePositiveInt(
        values['latency-writes'],
        _defaultLatencyWrites,
        'latency-writes',
      ),
      latencyBytes: _parsePositiveInt(
        values['latency-bytes'],
        _defaultLatencyBytes,
        'latency-bytes',
      ),
      churnCount: _parsePositiveInt(
        values['churn-count'],
        _defaultChurnCount,
        'churn-count',
      ),
      httpRequests: _parsePositiveInt(
        values['http-requests'],
        _defaultHttpRequests,
        'http-requests',
      ),
      emitJson: emitJson,
    );
  }

  static List<int> _parsePairs(String value, String name) {
    final pairs = value
        .split(',')
        .where((part) => part.trim().isNotEmpty)
        .map((part) => int.parse(part.trim()))
        .toList(growable: false);
    if (pairs.isEmpty || pairs.any((pair) => pair <= 0)) {
      throw ArgumentError('--$name must contain positive integers');
    }
    return pairs;
  }

  static int _parsePositiveInt(String? value, int fallback, String name) {
    if (value == null) return fallback;
    final parsed = int.parse(value);
    if (parsed <= 0) throw ArgumentError('--$name must be positive');
    return parsed;
  }

  static Never _printUsageAndExit() {
    print('Usage: dart run benchmark/fd_transport.dart [options]');
    print('');
    print('Options:');
    print('  --pairs=1,10,50,100       one-way/latency scales');
    print('  --extra-pairs=1           duplex/fairness scales');
    print('  --payload-mib=4           throughput payload per pair');
    print('  --chunk-kib=64            throughput write chunk size');
    print('  --latency-writes=200      small writes per pair');
    print('  --latency-bytes=64        small write payload size');
    print('  --churn-count=100         create/close pairs for churn test');
    print('  --http-requests=100       HTTP-shaped request/response loops');
    print('  --json                    emit machine-readable JSON');
    exit(0);
  }
}

final class _BenchResult {
  const _BenchResult({
    required this.name,
    required this.scale,
    required this.metrics,
  });

  final String name;
  final int scale;
  final Map<String, num> metrics;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'scale': scale,
    'metrics': metrics,
  };
}

final class _TransportPair {
  const _TransportPair(this.left, this.right);

  final PosixFdTransport left;
  final PosixFdTransport right;
}

final class _BenchPosixBindings {
  _BenchPosixBindings._()
    : _socketpair = DynamicLibrary.process()
          .lookupFunction<_SocketPairNative, _SocketPairDart>('socketpair'),
      _close = DynamicLibrary.process()
          .lookupFunction<_CloseNative, _CloseDart>('close');

  static final instance = _BenchPosixBindings._();

  final _SocketPairDart _socketpair;
  final _CloseDart _close;

  int socketpair(int domain, int type, int protocol, Pointer<Int32> fds) =>
      _socketpair(domain, type, protocol, fds);

  int close(int fd) => _close(fd);
}

typedef _SocketPairNative = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairDart = int Function(int, int, int, Pointer<Int32>);

typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
