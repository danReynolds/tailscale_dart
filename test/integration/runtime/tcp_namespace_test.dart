/// Coverage for the public `tcp` namespace.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;
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
    native.duneStop();
    clearProcessIntegrationState(configuredStateBaseDir);
  });

  group('tcp.dial before up()', () {
    test('throws TailscaleTcpException', () async {
      await expectLater(
        Tailscale.instance.tcp.dial('100.64.0.5', 22),
        throwsA(
          isA<TailscaleTcpException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.staleRuntime,
          ),
        ),
      );
    });
  });

  group('tcp.bind before up()', () {
    test('throws TailscaleTcpException', () async {
      await expectLater(
        Tailscale.instance.tcp.bind(port: 12345),
        throwsA(isA<TailscaleTcpException>()),
      );
    });
  });
}
