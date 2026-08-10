/// Coverage for the public `tls` namespace lifecycle contract.
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

  group('tls.bind before up()', () {
    test('throws TailscaleTlsException', () async {
      await expectLater(
        Tailscale.instance.tls.bind(port: 443),
        throwsA(isA<TailscaleTlsException>()),
      );
    });
  });
}
