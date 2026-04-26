/// Coverage for the `http` namespace on [Tailscale].
///
/// Focuses on the lifecycle contract around [Http.client] and
/// [Http.bind] — when they throw, when the client becomes available.
/// End-to-end exercise (HTTP actually flowing over the tailnet) lives
/// under `test/e2e/`.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    native.duneSetLogLevel(0);
    configuredStateBaseDir = Directory.systemTemp.createTempSync(
      'tailscale_http_',
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
    test('http.client throws TailscaleUsageException', () {
      expect(
        () => Tailscale.instance.http.client,
        throwsA(isA<TailscaleUsageException>()),
      );
    });

    test('http.bind() throws TailscaleHttpException', () async {
      await expectLater(
        Tailscale.instance.http.bind(port: 80),
        throwsA(isA<TailscaleHttpException>()),
      );
    });
  });

  group('after up()', () {
    setUpAll(() async {
      await Tailscale.instance.up(
        hostname: 'http-test',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
    });

    tearDownAll(() async {
      try {
        await Tailscale.instance.down();
      } catch (_) {}
    });

    test('http.client returns an http.Client', () {
      expect(Tailscale.instance.http.client, isA<http.Client>());
    });
  });
}
