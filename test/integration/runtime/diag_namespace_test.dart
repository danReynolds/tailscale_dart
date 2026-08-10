/// Coverage for helper-isolate calls in the public `diag` namespace.
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
    Tailscale.init(
      stateDir: configuredStateBaseDir.path,
      appId: processIntegrationAppId,
    );
  });

  tearDownAll(() async {
    await forgetProcessIntegrationState(configuredStateBaseDir);
  });

  test('diag.ping before up() retains stale-runtime classification', () async {
    await expectLater(
      Tailscale.instance.diag.ping('100.64.0.1'),
      throwsA(
        isA<TailscaleDiagException>().having(
          (error) => error.code,
          'code',
          TailscaleErrorCode.staleRuntime,
        ),
      ),
    );
  });
}
