/// Coverage for the `tcp` namespace.
///
/// Phase 3 ships `tcp.dial` (outbound loopback bridge). `tcp.bind`
/// arrives in a follow-up.
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

  group('tcp.bind', () {
    test('throws UnimplementedError (arrives in a follow-up)', () {
      expect(
        () => Tailscale.instance.tcp.bind(1234),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });
}
