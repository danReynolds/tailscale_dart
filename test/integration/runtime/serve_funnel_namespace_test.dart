/// Coverage for the public `serve` and `funnel` namespace lifecycle contract.
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
      'tailscale_serve_funnel_',
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

  group('before up()', () {
    test('serve.forward throws TailscaleServeException', () async {
      await expectLater(
        Tailscale.instance.serve.forward(tailnetPort: 443, localPort: 3000),
        throwsA(isA<TailscaleServeException>()),
      );
    });

    test('funnel.forward throws TailscaleFunnelException', () async {
      await expectLater(
        Tailscale.instance.funnel.forward(localPort: 3000),
        throwsA(isA<TailscaleFunnelException>()),
      );
    });
  });
}
