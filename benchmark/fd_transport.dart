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
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _afUnix = 1;
const _sockStream = 1;
const _defaultChunkKiB = 64;
const _defaultPayloadMiB = 4;
const _defaultLatencyWrites = 200;
const _defaultLatencyBytes = 64;
const _benchmarkTimeout = Duration(minutes: 2);

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
  print('payload per pair: ${options.payloadMiB} MiB');
  print('write chunk: ${options.chunkKiB} KiB');
  print('latency writes per pair: ${options.latencyWrites}');
  print('latency payload: ${options.latencyBytes} bytes');
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
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final mibPerSecond = (totalBytes / (1024 * 1024)) / seconds;
    return _BenchResult(
      name: 'throughput_one_way',
      pairs: pairs,
      metrics: <String, num>{
        'payload_mib_per_pair': payloadBytesPerPair / (1024 * 1024),
        'chunk_kib': chunkBytes / 1024,
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'total_mib': totalBytes / (1024 * 1024),
        'mib_per_second': mibPerSecond,
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

    final payload = Uint8List(payloadBytes);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i & 0xff;
    }

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
      pairs: pairs,
      metrics: <String, num>{
        'writes_per_pair': writesPerPair,
        'payload_bytes': payloadBytes,
        'elapsed_ms': elapsed.inMicroseconds / 1000,
        'writes_per_second':
            (pairs * writesPerPair) /
            (elapsed.inMicroseconds / Duration.microsecondsPerSecond),
        'p50_us': _percentile(latenciesUs, 50),
        'p95_us': _percentile(latenciesUs, 95),
        'p99_us': _percentile(latenciesUs, 99),
      },
    );
  } finally {
    await _closePairs(transports);
  }
}

Future<void> _writePayload(
  PosixFdTransport transport, {
  required int totalBytes,
  required int chunkBytes,
}) async {
  final chunk = Uint8List(chunkBytes);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = i & 0xff;
  }

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

num _percentile(List<int> values, int percentile) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  final index = ((percentile / 100) * (sorted.length - 1)).round();
  return sorted[index];
}

void _printResults(List<_BenchResult> results) {
  print('name                  pairs   metric');
  print('--------------------  ------  --------------------------------------');
  for (final result in results) {
    final metric = switch (result.name) {
      'throughput_one_way' =>
        '${_fmt(result.metrics['mib_per_second'])} MiB/s '
            '(${_fmt(result.metrics['total_mib'])} MiB in '
            '${_fmt(result.metrics['elapsed_ms'])} ms)',
      'write_latency' =>
        'p50 ${_fmt(result.metrics['p50_us'])} us, '
            'p95 ${_fmt(result.metrics['p95_us'])} us, '
            'p99 ${_fmt(result.metrics['p99_us'])} us, '
            '${_fmt(result.metrics['writes_per_second'])} writes/s',
      _ => result.metrics.toString(),
    };
    print(
      '${result.name.padRight(20)}  ${'${result.pairs}'.padLeft(6)}  $metric',
    );
  }
}

String _fmt(num? value) {
  if (value == null) return '0';
  if (value.abs() >= 100) return value.toStringAsFixed(0);
  if (value.abs() >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

final class _Options {
  const _Options({
    required this.pairs,
    required this.payloadMiB,
    required this.chunkKiB,
    required this.latencyWrites,
    required this.latencyBytes,
    required this.emitJson,
  });

  final List<int> pairs;
  final int payloadMiB;
  final int chunkKiB;
  final int latencyWrites;
  final int latencyBytes;
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
      pairs: _parsePairs(values['pairs'] ?? '1,10,50,100'),
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
      emitJson: emitJson,
    );
  }

  static List<int> _parsePairs(String value) {
    final pairs = value
        .split(',')
        .where((part) => part.trim().isNotEmpty)
        .map((part) => int.parse(part.trim()))
        .toList(growable: false);
    if (pairs.isEmpty || pairs.any((pair) => pair <= 0)) {
      throw ArgumentError('--pairs must contain positive integers');
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
    print('  --pairs=1,10,50,100       concurrent fd pairs to benchmark');
    print('  --payload-mib=4           throughput payload per pair');
    print('  --chunk-kib=64            throughput write chunk size');
    print('  --latency-writes=200      small writes per pair');
    print('  --latency-bytes=64        small write payload size');
    print('  --json                    emit machine-readable JSON');
    exit(0);
  }
}

final class _BenchResult {
  const _BenchResult({
    required this.name,
    required this.pairs,
    required this.metrics,
  });

  final String name;
  final int pairs;
  final Map<String, num> metrics;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'pairs': pairs,
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
