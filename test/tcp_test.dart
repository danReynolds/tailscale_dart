/// Coverage for the raw `tcp` namespace on [Tailscale].
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
    test('throws TailscaleUsageException', () async {
      await expectLater(
        Tailscale.instance.tcp.dial('100.64.0.5', 22),
        throwsA(isA<TailscaleUsageException>()),
      );
    });
  });

  group('tcp.bind before up()', () {
    test('throws TailscaleUsageException', () async {
      await expectLater(
        Tailscale.instance.tcp.bind(12345),
        throwsA(isA<TailscaleUsageException>()),
      );
    });
  });
}
