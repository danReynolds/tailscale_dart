/// Coverage for the public `serve` and `funnel` namespace lifecycle contract.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

import '../support/process_state_root.dart';

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    configuredStateBaseDir = processIntegrationStateRoot();
    clearProcessIntegrationState(configuredStateBaseDir);
    Tailscale.init(stateDir: configuredStateBaseDir.path);
  });

  tearDownAll(() async {
    try {
      await Tailscale.instance.down();
    } catch (_) {}
    clearProcessIntegrationState(configuredStateBaseDir);
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
