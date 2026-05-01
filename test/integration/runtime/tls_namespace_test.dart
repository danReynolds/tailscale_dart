/// Coverage for the public `tls` namespace lifecycle contract.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;
import 'package:tailscale/tailscale.dart';

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    native.duneSetLogLevel(0);
    configuredStateBaseDir = Directory.systemTemp.createTempSync(
      'tailscale_tls_',
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

  group('tls.bind before up()', () {
    test('throws TailscaleTlsException', () async {
      await expectLater(
        Tailscale.instance.tls.bind(port: 443),
        throwsA(isA<TailscaleTlsException>()),
      );
    });
  });
}
