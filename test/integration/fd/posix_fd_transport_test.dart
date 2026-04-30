import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/src/fd_transport.dart';
import 'package:test/test.dart';

import '../support/posix_fd_test_support.dart';

void main() {
  group(
    'PosixFdTransport',
    skip: Platform.isWindows ? 'POSIX only' : false,
    () {
      test('startup probe validates required POSIX syscall surface', () {
        expect(ensurePosixFdTransportAvailable, returnsNormally);
        expect(ensurePosixFdTransportAvailable, returnsNormally);
      });

      test('moves bytes bidirectionally over an adopted socketpair', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final leftInput = StreamIterator(left.input);
        final rightInput = StreamIterator(right.input);
        addTearDown(leftInput.cancel);
        addTearDown(rightInput.cancel);

        await left.write(Uint8List.fromList(<int>[1, 2, 3]));
        expect(await _moveNext(rightInput), isTrue);
        expect(rightInput.current, <int>[1, 2, 3]);

        await right.write(Uint8List.fromList(<int>[4, 5, 6]));
        expect(await _moveNext(leftInput), isTrue);
        expect(leftInput.current, <int>[4, 5, 6]);
      });

      test('copies write buffers before asynchronous delivery', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final rightInput = StreamIterator(right.input);
        addTearDown(rightInput.cancel);

        final payload = Uint8List.fromList(<int>[10, 20, 30]);
        final write = left.write(payload);
        payload.fillRange(0, payload.length, 99);
        await write;

        expect(await _moveNext(rightInput), isTrue);
        expect(rightInput.current, <int>[10, 20, 30]);
      });

      test('preserves queued write ordering before closeWrite EOF', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        final first = left.write(Uint8List.fromList(<int>[1]));
        final second = left.write(Uint8List.fromList(<int>[2, 3]));
        final closeWrite = left.closeWrite();
        await Future.wait(<Future<void>>[first, second, closeWrite]);

        final received = await right.input
            .expand((chunk) => chunk)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(received, <int>[1, 2, 3]);
      });

      test('closeWrite is a half-close; peer can still write back', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final leftInput = StreamIterator(left.input);
        final rightInput = StreamIterator(right.input);
        addTearDown(leftInput.cancel);
        addTearDown(rightInput.cancel);

        await left.closeWrite();
        expect(await _moveNext(rightInput), isFalse);

        await right.write(Uint8List.fromList(<int>[7, 8, 9]));
        expect(await _moveNext(leftInput), isTrue);
        expect(leftInput.current, <int>[7, 8, 9]);

        await right.closeWrite();
        expect(await _moveNext(leftInput), isFalse);
        await left.done.timeout(const Duration(seconds: 5));
        await right.done.timeout(const Duration(seconds: 5));
      });

      test('full close is idempotent and completes done', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        await left.close();
        await left.close();
        await left.done.timeout(const Duration(seconds: 5));
      });

      test('can adopt again immediately after the reactor goes idle', () async {
        for (var i = 0; i < 5; i++) {
          final (:left, :right) = await _connectedPair();
          final rightInput = StreamIterator(right.input);
          try {
            await left.write(Uint8List.fromList(<int>[i]));
            expect(await _moveNext(rightInput), isTrue);
            expect(rightInput.current, <int>[i]);
          } finally {
            await rightInput.cancel();
            await _closeBoth(left, right);
          }
        }
      });

      test('rejects writes after the write side is closed', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        await left.closeWrite();

        await expectLater(
          left.write(Uint8List.fromList(<int>[1])),
          throwsA(isA<StateError>()),
        );
      });

      test('bounds pending write bytes', () async {
        final (:left, :right) = await _connectedPair(maxPendingWriteBytes: 2);
        addTearDown(() => _closeBoth(left, right));

        await expectLater(
          left.write(Uint8List.fromList(<int>[1, 2, 3])),
          throwsA(isA<StateError>()),
        );
      });

      test('input is single-subscription', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final subscription = left.input.listen((_) {});
        addTearDown(subscription.cancel);

        expect(() => left.input.listen((_) {}), throwsA(isA<StateError>()));
      });

      test('paused input stops issuing additional fd reads', () async {
        final (:left, :right) = await _connectedPair(maxReadChunkSize: 1);
        addTearDown(() => _closeBoth(left, right));

        final received = <List<int>>[];
        final firstChunk = Completer<void>();
        final allChunks = Completer<void>();
        late final StreamSubscription<Uint8List> subscription;
        subscription = left.input.listen((chunk) {
          received.add(chunk);
          if (!firstChunk.isCompleted) {
            subscription.pause();
            firstChunk.complete();
          }
          if (received.expand((chunk) => chunk).length >= 3 &&
              !allChunks.isCompleted) {
            allChunks.complete();
          }
        });
        addTearDown(subscription.cancel);

        await right.write(Uint8List.fromList(<int>[1, 2, 3]));
        await firstChunk.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received.expand((chunk) => chunk).toList(), <int>[1]);

        subscription.resume();
        await allChunks.future.timeout(const Duration(seconds: 5));
        expect(received.expand((chunk) => chunk).toList(), <int>[1, 2, 3]);
      });

      test('inbound queue bound limits reactor read chunking', () async {
        final (:left, :right) = await _connectedPair(maxInboundQueuedBytes: 1);
        addTearDown(() => _closeBoth(left, right));

        final chunks = <int>[];
        final allChunks = Completer<void>();
        final subscription = right.input.listen((chunk) {
          chunks.add(chunk.length);
          if (chunks.length == 3 && !allChunks.isCompleted) {
            allChunks.complete();
          }
        });
        addTearDown(subscription.cancel);

        await left.write(Uint8List.fromList(<int>[1, 2, 3]));
        await allChunks.future.timeout(const Duration(seconds: 5));

        expect(chunks, <int>[1, 1, 1]);
      });

      test('transfers large payloads without corruption', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        final payload = Uint8List.fromList(
          List<int>.generate(512 * 1024, (index) => index & 0xff),
        );
        final receivedFuture = right.input
            .expand((chunk) => chunk)
            .take(payload.length)
            .toList()
            .timeout(const Duration(seconds: 5));

        await left.write(payload);
        expect(await receivedFuture, payload);
      });

      test('closeWrite waits for queued bytes before EOF', () async {
        final (:left, :right) = await _connectedPair(
          maxPendingWriteBytes: 3 * 1024 * 1024,
        );
        addTearDown(() => _closeBoth(left, right));

        final payload = Uint8List.fromList(
          List<int>.generate(2 * 1024 * 1024, (index) => index & 0xff),
        );
        final write = left.write(payload);
        final closeWrite = left.closeWrite();

        final received = await right.input
            .expand((chunk) => chunk)
            .toList()
            .timeout(const Duration(seconds: 10));

        await write.timeout(const Duration(seconds: 10));
        await closeWrite.timeout(const Duration(seconds: 10));
        expect(received.length, payload.length);
        expect(received, payload);
      });

      test('shared reactor supports many active transports', () async {
        final pairs = <({PosixFdTransport left, PosixFdTransport right})>[];
        addTearDown(() async {
          await Future.wait(
            pairs.map((pair) => _closeBoth(pair.left, pair.right)),
          );
        });

        for (var i = 0; i < 100; i++) {
          pairs.add(await _connectedPair());
        }

        final reads = <Future<List<int>>>[];
        for (var i = 0; i < pairs.length; i++) {
          reads.add(
            pairs[i].right.input
                .expand((chunk) => chunk)
                .take(3)
                .toList()
                .timeout(const Duration(seconds: 10)),
          );
        }

        await Future.wait(<Future<void>>[
          for (var i = 0; i < pairs.length; i++)
            pairs[i].left.write(Uint8List.fromList(<int>[i & 0xff, 1, 2])),
        ]);

        final received = await Future.wait(reads);
        for (var i = 0; i < received.length; i++) {
          expect(received[i], <int>[i & 0xff, 1, 2]);
        }
      });

      test('shared reactor exposes internal diagnostic counters', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        await left.write(Uint8List.fromList(<int>[1, 2, 3]));
        final rightInput = StreamIterator(right.input);
        addTearDown(rightInput.cancel);
        expect(await _moveNext(rightInput), isTrue);

        final snapshot = await debugPosixFdReactorSnapshot();
        expect(snapshot, isNotNull);
        expect(snapshot!.registeredTransports, greaterThanOrEqualTo(2));
        expect(snapshot.readSyscalls, greaterThan(0));
        expect(snapshot.writeSyscalls, greaterThan(0));
      });
    },
  );
}

Future<bool> _moveNext(StreamIterator<Uint8List> iterator) =>
    iterator.moveNext().timeout(const Duration(seconds: 5));

Future<({PosixFdTransport left, PosixFdTransport right})> _connectedPair({
  int maxReadChunkSize = 64 * 1024,
  int maxInboundQueuedBytes = 1024 * 1024,
  int maxPendingWriteBytes = 1024 * 1024,
}) async {
  final (:leftFd, :rightFd) = _socketPair();
  final left = await PosixFdTransport.adopt(
    leftFd,
    maxReadChunkSize: maxReadChunkSize,
    maxInboundQueuedBytes: maxInboundQueuedBytes,
    maxPendingWriteBytes: maxPendingWriteBytes,
  );
  try {
    final right = await PosixFdTransport.adopt(
      rightFd,
      maxReadChunkSize: maxReadChunkSize,
      maxInboundQueuedBytes: maxInboundQueuedBytes,
      maxPendingWriteBytes: maxPendingWriteBytes,
    );
    return (left: left, right: right);
  } catch (_) {
    await left.close();
    TestPosixBindings.instance.close(rightFd);
    rethrow;
  }
}

Future<void> _closeBoth(PosixFdTransport left, PosixFdTransport right) async {
  await Future.wait(<Future<void>>[left.close(), right.close()]);
}

({int leftFd, int rightFd}) _socketPair() {
  return socketPair(sockStream);
}
