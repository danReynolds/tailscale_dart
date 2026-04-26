/// Coverage for the public `udp` namespace.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/src/api/udp.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import 'support/posix_fd_test_support.dart';

void main() {
  group('TailscaleDatagram', () {
    test('value semantics include remote endpoint and payload', () {
      final a = TailscaleDatagram(
        remote: const TailscaleEndpoint(address: '100.64.0.1', port: 7001),
        payload: <int>[1, 2, 3],
      );
      final b = TailscaleDatagram(
        remote: const TailscaleEndpoint(address: '100.64.0.1', port: 7001),
        payload: <int>[1, 2, 3],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('bytes: 3'));
    });
  });

  group(
    'TailscaleDatagramBinding',
    skip: Platform.isWindows ? 'POSIX only' : false,
    () {
      test('moves message-preserving datagrams over fd backend', () async {
        final (:left, :right) = await _bindingPair();
        addTearDown(() => _closeBoth(left, right));

        final rightInput = StreamIterator(right.datagrams);
        addTearDown(rightInput.cancel);

        const remote = TailscaleEndpoint(address: '100.64.0.2', port: 7001);
        final first = _moveNext(rightInput);
        await Future<void>.delayed(Duration.zero);
        await left.send(<int>[1, 2, 3], to: remote);
        expect(await first, isTrue);
        expect(rightInput.current.remote, remote);
        expect(rightInput.current.payload, <int>[1, 2, 3]);

        final second = _moveNext(rightInput);
        await left.send(<int>[4, 5], to: remote);

        expect(await second, isTrue);
        expect(rightInput.current.payload, <int>[4, 5]);
      });

      test('rejects oversize datagrams instead of fragmenting', () async {
        final (:left, :right) = await _bindingPair();
        addTearDown(() => _closeBoth(left, right));

        await expectLater(
          left.send(
            List<int>.filled(tailscaleMaxDatagramPayloadBytes + 1, 1),
            to: const TailscaleEndpoint(address: '100.64.0.2', port: 7001),
          ),
          throwsA(isA<TailscaleUdpException>()),
        );
      });

      test('datagrams is single-subscription', () async {
        final (:left, :right) = await _bindingPair();
        addTearDown(() => _closeBoth(left, right));
        final subscription = left.datagrams.listen((_) {});
        addTearDown(subscription.cancel);

        expect(() => left.datagrams.listen((_) {}), throwsA(isA<StateError>()));
      });

      test('rejects malformed inbound datagram envelopes', () async {
        final (:leftFd, :rightFd) = _socketPair();
        final binding = await createFdTailscaleDatagramBinding(
          fd: leftFd,
          local: const TailscaleEndpoint(address: '100.64.0.1', port: 7001),
        );
        addTearDown(() async {
          await binding.close();
          TestPosixBindings.instance.close(rightFd);
        });

        final errorSeen = Completer<Object>();
        final subscription = binding.datagrams.listen(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (!errorSeen.isCompleted) errorSeen.complete(error);
          },
        );
        addTearDown(subscription.cancel);

        final written = TestPosixBindings.instance.write(
          rightFd,
          Uint8List.fromList(<int>[1, 0, 0, 1]),
        );
        expect(written, 4);

        final error = await errorSeen.future.timeout(
          const Duration(seconds: 5),
        );
        expect(error, isA<TailscaleUdpException>());
      });
    },
  );

  group('udp.bind before up()', () {
    late Directory configuredStateBaseDir;

    setUpAll(() {
      native.duneSetLogLevel(0);
      configuredStateBaseDir = Directory.systemTemp.createTempSync(
        'tailscale_udp_',
      );
      Tailscale.init(stateDir: configuredStateBaseDir.path);
    });

    tearDownAll(() async {
      try {
        await Tailscale.instance.down();
      } catch (_) {}
      native.duneStop();
      if (configuredStateBaseDir.existsSync()) {
        configuredStateBaseDir.deleteSync(recursive: true);
      }
    });

    test('throws TailscaleUdpException', () async {
      await expectLater(
        Tailscale.instance.udp.bind(address: '100.64.0.5', port: 12345),
        throwsA(isA<TailscaleUdpException>()),
      );
    });
  });
}

Future<bool> _moveNext(StreamIterator<TailscaleDatagram> iterator) =>
    iterator.moveNext().timeout(const Duration(seconds: 5));

Future<({TailscaleDatagramBinding left, TailscaleDatagramBinding right})>
_bindingPair() async {
  final (:leftFd, :rightFd) = _socketPair();
  final left = await createFdTailscaleDatagramBinding(
    fd: leftFd,
    local: const TailscaleEndpoint(address: '100.64.0.1', port: 7001),
  );
  try {
    final right = await createFdTailscaleDatagramBinding(
      fd: rightFd,
      local: const TailscaleEndpoint(address: '100.64.0.2', port: 7001),
    );
    return (left: left, right: right);
  } catch (_) {
    await left.close();
    TestPosixBindings.instance.close(rightFd);
    rethrow;
  }
}

Future<void> _closeBoth(
  TailscaleDatagramBinding left,
  TailscaleDatagramBinding right,
) async {
  await Future.wait(<Future<void>>[left.close(), right.close()]);
}

({int leftFd, int rightFd}) _socketPair() {
  return socketPair(sockDgram);
}
