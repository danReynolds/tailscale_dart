import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/src/runtime_connection.dart';
import 'package:test/test.dart';

import 'support/posix_fd_test_support.dart';

void main() {
  group(
    'RuntimeConnection',
    skip: Platform.isWindows ? 'POSIX only' : false,
    () {
      test('wraps an adopted fd as a byte-stream connection', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final rightInput = StreamIterator(right.input);
        addTearDown(rightInput.cancel);

        await left.write(<int>[1, 2, 3]);

        expect(await _moveNext(rightInput), isTrue);
        expect(rightInput.current, <int>[1, 2, 3]);
      });

      test('writeAll preserves source order and can close output', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        await left.writeAll(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1],
            Uint8List.fromList(<int>[2, 3]),
          ]),
          closeOutput: true,
        );

        final received = await right.input
            .expand((chunk) => chunk)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(received, <int>[1, 2, 3]);
      });

      test('writeAll source errors do not close output', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));

        final controller = StreamController<List<int>>();
        final writeAll = left.writeAll(controller.stream, closeOutput: true);
        final writeAllError = expectLater(writeAll, throwsA(isA<StateError>()));
        await Future<void>.delayed(Duration.zero);
        controller.add(<int>[1]);
        controller.addError(StateError('boom'));
        await controller.close();
        await writeAllError;

        await left.write(<int>[2]);
        await left.closeOutputGracefully();

        final received = await right.input
            .expand((chunk) => chunk)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(received, <int>[1, 2]);
      });

      test('closeOutputGracefully is a half-close', () async {
        final (:left, :right) = await _connectedPair();
        addTearDown(() => _closeBoth(left, right));
        final leftInput = StreamIterator(left.input);
        final rightInput = StreamIterator(right.input);
        addTearDown(leftInput.cancel);
        addTearDown(rightInput.cancel);

        await left.closeOutputGracefully();
        expect(await _moveNext(rightInput), isFalse);

        await right.write(<int>[4, 5, 6]);
        expect(await _moveNext(leftInput), isTrue);
        expect(leftInput.current, <int>[4, 5, 6]);
      });
    },
  );
}

Future<bool> _moveNext(StreamIterator<Uint8List> iterator) =>
    iterator.moveNext().timeout(const Duration(seconds: 5));

Future<({RuntimeConnection left, RuntimeConnection right})>
_connectedPair() async {
  final (:leftFd, :rightFd) = _socketPair();
  final left = await RuntimeConnection.adoptPosixFd(leftFd);
  try {
    final right = await RuntimeConnection.adoptPosixFd(rightFd);
    return (left: left, right: right);
  } catch (_) {
    await left.close();
    TestPosixBindings.instance.close(rightFd);
    rethrow;
  }
}

Future<void> _closeBoth(RuntimeConnection left, RuntimeConnection right) async {
  await Future.wait(<Future<void>>[left.close(), right.close()]);
}

({int leftFd, int rightFd}) _socketPair() {
  return socketPair(sockStream);
}
