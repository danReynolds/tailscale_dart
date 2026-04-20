/// Coverage for the `tcp` namespace — both the outbound `dial` and
/// inbound `bind` loopback bridges.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    native.duneSetLogLevel(0);
    configuredStateBaseDir = Directory.systemTemp.createTempSync(
      'tailscale_tcp_',
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

  group('tcp.dial before up()', () {
    test('throws TailscaleTcpException', () async {
      await expectLater(
        Tailscale.instance.tcp.dial('100.64.0.5', 22),
        throwsA(isA<TailscaleTcpException>()),
      );
    });
  });

  group('tcp.bind before up()', () {
    test('throws TailscaleTcpException', () async {
      await expectLater(
        Tailscale.instance.tcp.bind(12345),
        throwsA(isA<TailscaleTcpException>()),
      );
    });
  });

  group('tcp.dial timeout budget', () {
    test('counts time spent before the loopback connect stage', () async {
      final loopback = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(loopback.close);

      final tcp = Tcp.internal(
        dialFn: (_, __, ___) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return (loopbackPort: loopback.port, token: 'token');
        },
        bindFn: (_, __, ___) async => throw UnimplementedError(),
        unbindFn: (_) async {},
      );

      await expectLater(
        tcp.dial('peer', 443, timeout: const Duration(milliseconds: 10)),
        throwsA(
          isA<TailscaleTcpException>().having(
            (e) => e.message,
            'message',
            contains('timeout budget'),
          ),
        ),
      );
    });
  });
}
