library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

const profileSpeedTestPort = 7002;

/// The one canonical sustained-transfer workload used by host and device runs.
const canonicalSpeedTestConfig = SpeedTestConfig(
  workloadId: 'tcp-sustained-v2',
  measuredDuration: Duration(seconds: 5),
  warmupBytes: 1024 * 1024,
  chunkBytes: 64 * 1024,
  maxInFlightBytes: 512 * 1024,
  interval: Duration(seconds: 1),
);

/// Short diagnostic ceiling check for the ordinary-LAN control.
///
/// It keeps the sustained workload's chunk and write-window shape, but runs
/// for one second so a loopback host cannot copy tens of gigabytes and distort
/// the Tailscale samples through allocator, scheduler, or thermal pressure.
const ordinaryLanControlConfig = SpeedTestConfig(
  workloadId: 'tcp-lan-control-v1',
  measuredDuration: Duration(seconds: 1),
  warmupBytes: 1024 * 1024,
  chunkBytes: 64 * 1024,
  maxInFlightBytes: 512 * 1024,
  interval: Duration(seconds: 1),
);

enum SpeedTestDirection { upload, download }

/// Versioned workload parameters. Changing any field starts a new history.
final class SpeedTestConfig {
  const SpeedTestConfig({
    required this.workloadId,
    required this.measuredDuration,
    required this.warmupBytes,
    required this.chunkBytes,
    required this.maxInFlightBytes,
    required this.interval,
  });

  final String workloadId;
  final Duration measuredDuration;
  final int warmupBytes;
  final int chunkBytes;
  final int maxInFlightBytes;
  final Duration interval;

  void validate() {
    if (workloadId.isEmpty ||
        measuredDuration <= Duration.zero ||
        measuredDuration > const Duration(seconds: 30) ||
        warmupBytes < 0 ||
        warmupBytes > 64 * 1024 * 1024 ||
        chunkBytes <= 1 ||
        chunkBytes > 1024 * 1024 ||
        maxInFlightBytes < chunkBytes ||
        maxInFlightBytes > 4 * 1024 * 1024 ||
        maxInFlightBytes % chunkBytes != 0 ||
        warmupBytes % chunkBytes != 0 ||
        interval <= Duration.zero ||
        interval > measuredDuration) {
      throw ArgumentError('invalid speed-test configuration: ${toJson()}');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'workloadId': workloadId,
    'measuredDurationUs': measuredDuration.inMicroseconds,
    'warmupBytes': warmupBytes,
    'chunkBytes': chunkBytes,
    'maxInFlightBytes': maxInFlightBytes,
    'intervalUs': interval.inMicroseconds,
    'streamCount': 1,
  };

  factory SpeedTestConfig.fromJson(Map<String, Object?> json) {
    if (json['streamCount'] != 1 || json['workloadId'] is! String) {
      throw const FormatException('unsupported speed-test configuration');
    }
    final config = SpeedTestConfig(
      workloadId: json['workloadId']! as String,
      measuredDuration: Duration(
        microseconds: _requiredInt(json, 'measuredDurationUs'),
      ),
      warmupBytes: _requiredInt(json, 'warmupBytes'),
      chunkBytes: _requiredInt(json, 'chunkBytes'),
      maxInFlightBytes: _requiredInt(json, 'maxInFlightBytes'),
      interval: Duration(microseconds: _requiredInt(json, 'intervalUs')),
    );
    config.validate();
    return config;
  }
}

/// Completion latency of the sender's bounded `write()` calls.
///
/// This is deliberately separate from throughput: it can expose scheduling or
/// local-transport stalls without turning a latency-bound write loop into the
/// sustained-transfer measurement itself.
final class SpeedTestWriteStats {
  const SpeedTestWriteStats({
    required this.sampleCount,
    required this.minUs,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.maxUs,
  });

  factory SpeedTestWriteStats.fromSamples(List<int> samples) {
    if (samples.isEmpty) {
      throw ArgumentError('write-completion samples must not be empty');
    }
    final sorted = List<int>.of(samples)..sort();
    int percentile(double value) {
      final index = (sorted.length * value).ceil() - 1;
      return sorted[index.clamp(0, sorted.length - 1)];
    }

    return SpeedTestWriteStats(
      sampleCount: sorted.length,
      minUs: sorted.first,
      p50Us: percentile(0.50),
      p95Us: percentile(0.95),
      p99Us: percentile(0.99),
      maxUs: sorted.last,
    );
  }

  factory SpeedTestWriteStats.fromJson(Map<String, Object?> json) {
    final result = SpeedTestWriteStats(
      sampleCount: _requiredInt(json, 'sampleCount'),
      minUs: _requiredInt(json, 'minUs'),
      p50Us: _requiredInt(json, 'p50Us'),
      p95Us: _requiredInt(json, 'p95Us'),
      p99Us: _requiredInt(json, 'p99Us'),
      maxUs: _requiredInt(json, 'maxUs'),
    );
    if (!result.valid) {
      throw const FormatException('invalid write-completion statistics');
    }
    return result;
  }

  final int sampleCount;
  final int minUs;
  final int p50Us;
  final int p95Us;
  final int p99Us;
  final int maxUs;

  bool get valid =>
      sampleCount > 0 &&
      minUs >= 0 &&
      minUs <= p50Us &&
      p50Us <= p95Us &&
      p95Us <= p99Us &&
      p99Us <= maxUs;

  Map<String, Object?> toJson() => <String, Object?>{
    'sampleCount': sampleCount,
    'minUs': minUs,
    'p50Us': p50Us,
    'p95Us': p95Us,
    'p99Us': p99Us,
    'maxUs': maxUs,
  };
}

final class SpeedTestInterval {
  const SpeedTestInterval({
    required this.startUs,
    required this.endUs,
    required this.bytes,
  });

  final int startUs;
  final int endUs;
  final int bytes;

  double get mibPerSecond => _mibPerSecond(bytes, endUs - startUs);

  Map<String, Object?> toJson() => <String, Object?>{
    'startUs': startUs,
    'endUs': endUs,
    'bytes': bytes,
    'mibPerSecond': mibPerSecond,
  };

  factory SpeedTestInterval.fromJson(Map<String, Object?> json) =>
      SpeedTestInterval(
        startUs: _requiredInt(json, 'startUs'),
        endUs: _requiredInt(json, 'endUs'),
        bytes: _requiredInt(json, 'bytes'),
      );
}

/// One complete directional run. This—not its intervals—is a sample.
final class SpeedTestResult {
  const SpeedTestResult({
    required this.config,
    required this.direction,
    required this.senderBytes,
    required this.receiverBytes,
    required this.senderElapsedUs,
    required this.receiverElapsedUs,
    required this.writeCompletion,
    required this.intervals,
  });

  final SpeedTestConfig config;
  final SpeedTestDirection direction;
  final int senderBytes;
  final int receiverBytes;
  final int senderElapsedUs;
  final int receiverElapsedUs;
  final SpeedTestWriteStats writeCompletion;
  final List<SpeedTestInterval> intervals;

  bool get valid =>
      senderBytes > 0 &&
      senderBytes == receiverBytes &&
      senderElapsedUs >= config.measuredDuration.inMicroseconds &&
      receiverElapsedUs > 0 &&
      writeCompletion.valid &&
      writeCompletion.sampleCount == senderBytes ~/ config.chunkBytes &&
      intervals.isNotEmpty &&
      _validIntervals(intervals, receiverElapsedUs) &&
      intervals.fold<int>(0, (sum, value) => sum + value.bytes) ==
          receiverBytes;

  double get mibPerSecond => _mibPerSecond(receiverBytes, receiverElapsedUs);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 2,
    'config': config.toJson(),
    'direction': direction.name,
    'senderBytes': senderBytes,
    'receiverBytes': receiverBytes,
    'senderElapsedUs': senderElapsedUs,
    'receiverElapsedUs': receiverElapsedUs,
    'mibPerSecond': mibPerSecond,
    'writeCompletion': writeCompletion.toJson(),
    'valid': valid,
    'intervals': [for (final value in intervals) value.toJson()],
  };

  factory SpeedTestResult.fromJson(Map<String, Object?> json) {
    if (json['schema'] != 2 ||
        json['config'] is! Map ||
        json['writeCompletion'] is! Map) {
      throw const FormatException('unsupported speed-test result');
    }
    final directions = SpeedTestDirection.values.where(
      (value) => value.name == json['direction'],
    );
    if (directions.length != 1 || json['intervals'] is! List) {
      throw const FormatException('invalid speed-test result');
    }
    final result = SpeedTestResult(
      config: SpeedTestConfig.fromJson(
        Map<String, Object?>.from(json['config']! as Map),
      ),
      direction: directions.single,
      senderBytes: _requiredInt(json, 'senderBytes'),
      receiverBytes: _requiredInt(json, 'receiverBytes'),
      senderElapsedUs: _requiredInt(json, 'senderElapsedUs'),
      receiverElapsedUs: _requiredInt(json, 'receiverElapsedUs'),
      writeCompletion: SpeedTestWriteStats.fromJson(
        Map<String, Object?>.from(json['writeCompletion']! as Map),
      ),
      intervals: List<SpeedTestInterval>.unmodifiable(
        (json['intervals']! as List).map(
          (value) => SpeedTestInterval.fromJson(
            Map<String, Object?>.from(value as Map),
          ),
        ),
      ),
    );
    if (!result.valid) {
      throw const FormatException('invalid speed-test byte accounting');
    }
    return result;
  }
}

/// Dependency-free adapter implemented by the host and Flutter callers.
final class SpeedTestConnection {
  const SpeedTestConnection({
    required this.input,
    required this.write,
    required this.close,
  });

  /// Adapts a buffered sink such as `dart:io`'s `Socket`.
  ///
  /// Multiple writes made in one event-loop turn share one flush. This matches
  /// the harness's bounded write window without issuing concurrent `flush()`
  /// calls, which `IOSink` rejects.
  factory SpeedTestConnection.bufferedSink({
    required Stream<List<int>> input,
    required void Function(List<int> bytes) add,
    required Future<void> Function() flush,
    required Future<void> Function() close,
  }) {
    final writer = _BufferedSinkWriter(add, flush);
    return SpeedTestConnection(
      input: input,
      write: writer.write,
      close: () async {
        await writer.settled;
        await close();
      },
    );
  }

  final Stream<List<int>> input;
  final Future<void> Function(List<int> bytes) write;
  final Future<void> Function() close;
}

final class _BufferedSinkWriter {
  _BufferedSinkWriter(this._add, this._flush);

  final void Function(List<int> bytes) _add;
  final Future<void> Function() _flush;
  Completer<void>? _pending;

  Future<void> get settled => _pending?.future ?? Future<void>.value();

  Future<void> write(List<int> bytes) {
    try {
      _add(bytes);
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    final pending = _pending;
    if (pending != null) return pending.future;

    final completer = Completer<void>();
    _pending = completer;
    scheduleMicrotask(() async {
      try {
        await _flush();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_pending, completer)) _pending = null;
      }
    });
    return completer.future;
  }
}

final class SpeedTestProtocolException implements Exception {
  const SpeedTestProtocolException(this.message);

  final String message;

  @override
  String toString() => 'SpeedTestProtocolException: $message';
}

Future<SpeedTestResult> runSpeedTestClient(
  SpeedTestConnection connection, {
  required SpeedTestDirection direction,
  SpeedTestConfig config = canonicalSpeedTestConfig,
  Duration timeout = const Duration(seconds: 45),
}) async {
  config.validate();
  try {
    return await _runClient(connection, direction, config).timeout(timeout);
  } finally {
    await connection.close();
  }
}

Future<SpeedTestResult> serveSpeedTestConnection(
  SpeedTestConnection connection, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  try {
    return await _runServer(connection).timeout(timeout);
  } catch (error) {
    try {
      await _writeControl(connection, 'error', <String, Object?>{
        'message': error.toString(),
      });
    } catch (_) {}
    rethrow;
  } finally {
    await connection.close();
  }
}

Future<SpeedTestResult> _runClient(
  SpeedTestConnection connection,
  SpeedTestDirection direction,
  SpeedTestConfig config,
) async {
  final reader = _ByteReader(connection.input);
  try {
    await _writeControl(connection, 'start', <String, Object?>{
      'protocol': 2,
      'direction': direction.name,
      'config': config.toJson(),
    });
    await _expectControl(reader, 'ready');
    switch (direction) {
      case SpeedTestDirection.upload:
        return await _runSender(connection, reader, direction, config);
      case SpeedTestDirection.download:
        return await _runReceiver(connection, reader, direction, config);
    }
  } finally {
    await reader.cancel();
  }
}

Future<SpeedTestResult> _runServer(SpeedTestConnection connection) async {
  final reader = _ByteReader(connection.input);
  try {
    final request = await _expectControl(reader, 'start');
    if (request['protocol'] != 2 || request['config'] is! Map) {
      throw const SpeedTestProtocolException('unsupported protocol');
    }
    final directions = SpeedTestDirection.values.where(
      (value) => value.name == request['direction'],
    );
    if (directions.length != 1) {
      throw const SpeedTestProtocolException('invalid direction');
    }
    final direction = directions.single;
    final config = SpeedTestConfig.fromJson(
      Map<String, Object?>.from(request['config']! as Map),
    );
    await _writeControl(connection, 'ready');
    switch (direction) {
      case SpeedTestDirection.upload:
        return await _runReceiver(connection, reader, direction, config);
      case SpeedTestDirection.download:
        return await _runSender(connection, reader, direction, config);
    }
  } finally {
    await reader.cancel();
  }
}

Future<SpeedTestResult> _runSender(
  SpeedTestConnection connection,
  _ByteReader reader,
  SpeedTestDirection direction,
  SpeedTestConfig config,
) async {
  await _sendWarmup(connection, config);
  await _expectControl(reader, 'warmupAck');
  final sent = await _sendMeasurement(connection, config);
  final response = await _expectControl(reader, 'result');
  if (response['result'] is! Map) {
    throw const SpeedTestProtocolException('missing speed-test result');
  }
  final result = SpeedTestResult.fromJson(
    Map<String, Object?>.from(response['result']! as Map),
  );
  _validateSender(result, sent, direction, config);
  await _writeControl(connection, 'finalAck');
  return result;
}

Future<SpeedTestResult> _runReceiver(
  SpeedTestConnection connection,
  _ByteReader reader,
  SpeedTestDirection direction,
  SpeedTestConfig config,
) async {
  await reader.discard(config.warmupBytes);
  await _writeControl(connection, 'warmupAck');
  final result = await _receiveMeasurement(reader, config, direction);
  await _writeControl(connection, 'result', <String, Object?>{
    'result': result.toJson(),
  });
  await _expectControl(reader, 'finalAck');
  return result;
}

Future<void> _sendWarmup(
  SpeedTestConnection connection,
  SpeedTestConfig config,
) async {
  final chunk = Uint8List(config.chunkBytes);
  final writesPerBatch = config.maxInFlightBytes ~/ config.chunkBytes;
  for (var sent = 0; sent < config.warmupBytes;) {
    final writes = <Future<void>>[];
    while (writes.length < writesPerBatch && sent < config.warmupBytes) {
      writes.add(connection.write(chunk));
      sent += config.chunkBytes;
    }
    await Future.wait(writes);
  }
}

Future<_SentMeasurement> _sendMeasurement(
  SpeedTestConnection connection,
  SpeedTestConfig config,
) async {
  final chunk = Uint8List(config.chunkBytes);
  final watch = Stopwatch()..start();
  final completionUs = <int>[];
  final writesPerBatch = config.maxInFlightBytes ~/ config.chunkBytes;
  var bytes = 0;
  do {
    final writes = ListQueue<Future<void>>();
    for (var i = 0; i < writesPerBatch; i++) {
      final startedUs = watch.elapsedMicroseconds;
      writes.add(
        connection.write(chunk).then((_) {
          completionUs.add(watch.elapsedMicroseconds - startedUs);
        }),
      );
      bytes += chunk.length;
    }
    await Future.wait(writes);
  } while (watch.elapsed < config.measuredDuration);
  watch.stop();
  final sent = _SentMeasurement(
    bytes,
    watch.elapsedMicroseconds,
    SpeedTestWriteStats.fromSamples(completionUs),
  );
  final endMarker = Uint8List(config.chunkBytes)..first = 1;
  await connection.write(endMarker);
  await _writeControl(connection, 'measurement', <String, Object?>{
    'senderBytes': sent.bytes,
    'senderElapsedUs': sent.elapsedUs,
    'writeCompletion': sent.writeCompletion.toJson(),
  });
  return sent;
}

Future<SpeedTestResult> _receiveMeasurement(
  _ByteReader reader,
  SpeedTestConfig config,
  SpeedTestDirection direction,
) async {
  final watch = Stopwatch()..start();
  var totalBytes = 0;
  var intervalBytes = 0;
  var intervalStartUs = 0;
  final intervals = <SpeedTestInterval>[];
  while (true) {
    if (await reader.readMeasurementFrame(config.chunkBytes)) break;
    totalBytes += config.chunkBytes;
    intervalBytes += config.chunkBytes;
    final nowUs = watch.elapsedMicroseconds;
    if (nowUs - intervalStartUs >= config.interval.inMicroseconds) {
      intervals.add(
        SpeedTestInterval(
          startUs: intervalStartUs,
          endUs: nowUs,
          bytes: intervalBytes,
        ),
      );
      intervalStartUs = nowUs;
      intervalBytes = 0;
    }
  }
  watch.stop();
  final trailer = await _expectControl(reader, 'measurement');
  final elapsedUs = watch.elapsedMicroseconds;
  if (intervalBytes > 0) {
    intervals.add(
      SpeedTestInterval(
        startUs: intervalStartUs,
        endUs: elapsedUs,
        bytes: intervalBytes,
      ),
    );
  } else if (intervals.isNotEmpty && intervals.last.endUs < elapsedUs) {
    final last = intervals.removeLast();
    intervals.add(
      SpeedTestInterval(
        startUs: last.startUs,
        endUs: elapsedUs,
        bytes: last.bytes,
      ),
    );
  }
  final result = SpeedTestResult(
    config: config,
    direction: direction,
    senderBytes: _requiredInt(trailer, 'senderBytes'),
    receiverBytes: totalBytes,
    senderElapsedUs: _requiredInt(trailer, 'senderElapsedUs'),
    receiverElapsedUs: elapsedUs,
    writeCompletion: SpeedTestWriteStats.fromJson(
      Map<String, Object?>.from(_requiredMap(trailer, 'writeCompletion')),
    ),
    intervals: List<SpeedTestInterval>.unmodifiable(intervals),
  );
  if (!result.valid) {
    throw const SpeedTestProtocolException('invalid measurement accounting');
  }
  return result;
}

void _validateSender(
  SpeedTestResult result,
  _SentMeasurement sent,
  SpeedTestDirection direction,
  SpeedTestConfig config,
) {
  if (result.direction != direction ||
      !_sameConfig(result.config, config) ||
      result.senderBytes != sent.bytes ||
      result.senderElapsedUs != sent.elapsedUs ||
      !_sameWriteStats(result.writeCompletion, sent.writeCompletion) ||
      !result.valid) {
    throw const SpeedTestProtocolException('peer returned mismatched result');
  }
}

Future<void> _writeControl(
  SpeedTestConnection connection,
  String type, [
  Map<String, Object?> fields = const <String, Object?>{},
]) => connection.write(
  utf8.encode('${jsonEncode(<String, Object?>{'type': type, ...fields})}\n'),
);

Future<Map<String, Object?>> _expectControl(
  _ByteReader reader,
  String type,
) async {
  final line = await reader.readLine();
  final decoded = jsonDecode(utf8.decode(line));
  if (decoded is! Map) {
    throw const SpeedTestProtocolException('invalid control message');
  }
  final control = Map<String, Object?>.from(decoded);
  if (control['type'] == 'error') {
    throw SpeedTestProtocolException(
      'remote error: ${control['message'] ?? 'unknown'}',
    );
  }
  if (control['type'] != type) {
    throw SpeedTestProtocolException('expected $type control message');
  }
  return control;
}

final class _ByteReader {
  _ByteReader(Stream<List<int>> input) : _iterator = StreamIterator(input);

  static const _maxControlBytes = 64 * 1024;

  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const <int>[];
  int _offset = 0;

  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      await _ensureBytes();
      final count = (length - written).clamp(0, _chunk.length - _offset);
      result.setRange(written, written + count, _chunk, _offset);
      written += count;
      _offset += count;
    }
    return result;
  }

  Future<void> discard(int length) async {
    var remaining = length;
    while (remaining > 0) {
      await _ensureBytes();
      final count = remaining.clamp(0, _chunk.length - _offset);
      remaining -= count;
      _offset += count;
    }
  }

  /// Consumes one fixed-size measurement frame without copying its payload.
  ///
  /// Data frames are identified by a leading zero. The terminal frame starts
  /// with one and must otherwise be zero-filled. Avoiding [read]'s fresh
  /// allocation matters for sustained receivers, especially a fast loopback
  /// control that can otherwise manufacture tens of thousands of 64 KiB
  /// buffers per second solely to inspect this marker.
  Future<bool> readMeasurementFrame(int length) async {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    await _ensureBytes();
    final first = _chunk[_offset++];
    if (first != 0 && first != 1) {
      throw const SpeedTestProtocolException('invalid measurement chunk');
    }

    var remaining = length - 1;
    while (remaining > 0) {
      await _ensureBytes();
      final count = remaining.clamp(0, _chunk.length - _offset);
      if (first == 1) {
        for (var i = _offset; i < _offset + count; i++) {
          if (_chunk[i] != 0) {
            throw const SpeedTestProtocolException(
              'invalid measurement marker',
            );
          }
        }
      }
      remaining -= count;
      _offset += count;
    }
    return first == 1;
  }

  Future<Uint8List> readLine() async {
    final bytes = BytesBuilder(copy: false);
    while (true) {
      await _ensureBytes();
      final newline = _chunk.indexOf(0x0a, _offset);
      final end = newline < 0 ? _chunk.length : newline;
      bytes.add(_chunk.sublist(_offset, end));
      if (bytes.length > _maxControlBytes) {
        throw const SpeedTestProtocolException('control message is too large');
      }
      _offset = newline < 0 ? end : newline + 1;
      if (newline >= 0) return bytes.takeBytes();
    }
  }

  Future<void> _ensureBytes() async {
    while (_offset >= _chunk.length) {
      if (!await _iterator.moveNext()) {
        throw const SpeedTestProtocolException('unexpected end of stream');
      }
      _chunk = _iterator.current;
      _offset = 0;
    }
  }

  Future<void> cancel() => _iterator.cancel();
}

final class _SentMeasurement {
  const _SentMeasurement(this.bytes, this.elapsedUs, this.writeCompletion);

  final int bytes;
  final int elapsedUs;
  final SpeedTestWriteStats writeCompletion;
}

int _requiredInt(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

Map<Object?, Object?> _requiredMap(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value;
}

double _mibPerSecond(int bytes, int elapsedUs) {
  if (elapsedUs <= 0) return 0;
  return (bytes / (1024 * 1024)) / (elapsedUs / Duration.microsecondsPerSecond);
}

bool _sameConfig(SpeedTestConfig left, SpeedTestConfig right) =>
    left.workloadId == right.workloadId &&
    left.measuredDuration == right.measuredDuration &&
    left.warmupBytes == right.warmupBytes &&
    left.chunkBytes == right.chunkBytes &&
    left.maxInFlightBytes == right.maxInFlightBytes &&
    left.interval == right.interval;

bool _sameWriteStats(SpeedTestWriteStats left, SpeedTestWriteStats right) =>
    left.sampleCount == right.sampleCount &&
    left.minUs == right.minUs &&
    left.p50Us == right.p50Us &&
    left.p95Us == right.p95Us &&
    left.p99Us == right.p99Us &&
    left.maxUs == right.maxUs;

bool _validIntervals(List<SpeedTestInterval> intervals, int elapsedUs) {
  var expectedStartUs = 0;
  for (final interval in intervals) {
    if (interval.startUs != expectedStartUs ||
        interval.endUs <= interval.startUs ||
        interval.endUs > elapsedUs ||
        interval.bytes <= 0) {
      return false;
    }
    expectedStartUs = interval.endUs;
  }
  return expectedStartUs == elapsedUs;
}
