import 'dart:async';

import 'package:tailscale_profile_harness/tailscale_profile_harness.dart';
import 'package:test/test.dart';

const _testConfig = SpeedTestConfig(
  workloadId: 'test-v1',
  measuredDuration: Duration(milliseconds: 20),
  warmupBytes: 1024,
  chunkBytes: 1024,
  maxInFlightBytes: 4 * 1024,
  interval: Duration(milliseconds: 5),
);

void main() {
  for (final direction in SpeedTestDirection.values) {
    test('${direction.name} uses matching receiver-side accounting', () async {
      final pair = _memoryPair();
      final server = serveSpeedTestConnection(pair.server);
      final client = runSpeedTestClient(
        pair.client,
        direction: direction,
        config: _testConfig,
      );

      final results = await Future.wait([client, server]);
      expect(results[0].toJson(), results[1].toJson());
      expect(results[0].valid, isTrue);
      expect(results[0].senderBytes, results[0].receiverBytes);
      expect(results[0].senderElapsedUs, greaterThanOrEqualTo(20000));
      expect(results[0].intervals, isNotEmpty);
      expect(
        results[0].intervals.fold<int>(0, (sum, value) => sum + value.bytes),
        results[0].receiverBytes,
      );
      expect(results[0].mibPerSecond, greaterThan(0));
      expect(results[0].writeCompletion.valid, isTrue);
      expect(
        results[0].writeCompletion.sampleCount,
        results[0].senderBytes ~/ _testConfig.chunkBytes,
      );
      final senderWrites = direction == SpeedTestDirection.upload
          ? pair.clientWrites
          : pair.serverWrites;
      expect(senderWrites.maxInFlight, greaterThan(1));
    });
  }

  test('result serialization rejects mismatched byte counts', () {
    final json = <String, Object?>{
      'schema': 2,
      'config': _testConfig.toJson(),
      'direction': 'upload',
      'senderBytes': 2048,
      'receiverBytes': 1024,
      'senderElapsedUs': 20000,
      'receiverElapsedUs': 20000,
      'writeCompletion': const SpeedTestWriteStats(
        sampleCount: 2,
        minUs: 1,
        p50Us: 1,
        p95Us: 2,
        p99Us: 2,
        maxUs: 2,
      ).toJson(),
      'intervals': [
        const SpeedTestInterval(startUs: 0, endUs: 20000, bytes: 1024).toJson(),
      ],
    };

    expect(() => SpeedTestResult.fromJson(json), throwsFormatException);
  });

  test('configuration changes remain visible in the result contract', () {
    expect(canonicalSpeedTestConfig.toJson(), {
      'workloadId': 'tcp-sustained-v2',
      'measuredDurationUs': 5000000,
      'warmupBytes': 1048576,
      'chunkBytes': 65536,
      'maxInFlightBytes': 524288,
      'intervalUs': 1000000,
      'streamCount': 1,
    });
    expect(ordinaryLanControlConfig.toJson(), {
      'workloadId': 'tcp-lan-control-v1',
      'measuredDurationUs': 1000000,
      'warmupBytes': 1048576,
      'chunkBytes': 65536,
      'maxInFlightBytes': 524288,
      'intervalUs': 1000000,
      'streamCount': 1,
    });
  });

  test('buffered sink coalesces concurrent writes behind one flush', () async {
    final added = <int>[];
    var flushes = 0;
    var closed = false;
    final connection = SpeedTestConnection.bufferedSink(
      input: const Stream<List<int>>.empty(),
      add: added.addAll,
      flush: () async {
        flushes++;
        await Future<void>.delayed(Duration.zero);
      },
      close: () async => closed = true,
    );

    await Future.wait([
      connection.write([1, 2]),
      connection.write([3, 4]),
    ]);
    await connection.close();

    expect(added, [1, 2, 3, 4]);
    expect(flushes, 1);
    expect(closed, isTrue);
  });
}

({
  SpeedTestConnection client,
  SpeedTestConnection server,
  _WriteTracker clientWrites,
  _WriteTracker serverWrites,
})
_memoryPair() {
  final clientToServer = StreamController<List<int>>();
  final serverToClient = StreamController<List<int>>();
  final clientWrites = _WriteTracker();
  final serverWrites = _WriteTracker();
  var clientClosed = false;
  var serverClosed = false;

  Future<void> fragmentedWrite(
    StreamController<List<int>> target,
    List<int> bytes,
    _WriteTracker tracker,
  ) async {
    tracker.start();
    try {
      final split = bytes.length ~/ 3;
      if (split > 0) {
        target.add(bytes.sublist(0, split));
        target.add(bytes.sublist(split));
      } else {
        target.add(bytes);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    } finally {
      tracker.finish();
    }
  }

  return (
    client: SpeedTestConnection(
      input: serverToClient.stream,
      write: (bytes) => fragmentedWrite(clientToServer, bytes, clientWrites),
      close: () async {
        if (clientClosed) return;
        clientClosed = true;
        await clientToServer.close();
      },
    ),
    server: SpeedTestConnection(
      input: clientToServer.stream,
      write: (bytes) => fragmentedWrite(serverToClient, bytes, serverWrites),
      close: () async {
        if (serverClosed) return;
        serverClosed = true;
        await serverToClient.close();
      },
    ),
    clientWrites: clientWrites,
    serverWrites: serverWrites,
  );
}

final class _WriteTracker {
  int _inFlight = 0;
  int maxInFlight = 0;

  void start() {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
  }

  void finish() => _inFlight--;
}
