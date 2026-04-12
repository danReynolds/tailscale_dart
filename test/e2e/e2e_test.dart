/// End-to-end test against a real Headscale control server.
///
/// Run via: test/e2e/run_e2e.sh (handles Docker setup and teardown).
///
/// Required environment variables:
///   HEADSCALE_URL      - e.g. http://localhost:8080
///   HEADSCALE_AUTH_KEY  - pre-auth key from headscale
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  final controlUrl = Platform.environment['HEADSCALE_URL'];
  final authKey = Platform.environment['HEADSCALE_AUTH_KEY'];

  if (controlUrl == null || authKey == null) {
    print('Skipping E2E tests: HEADSCALE_URL and HEADSCALE_AUTH_KEY required.');
    print('Run test/e2e/run_e2e.sh to set up the environment.');
    return;
  }

  late Tailscale tsnet;
  late String stateDir;

  setUpAll(() {
    stateDir = Directory.systemTemp.createTempSync('tailscale_e2e_').path;
    Tailscale.init(stateDir: stateDir);
    tsnet = Tailscale.instance;
  });

  tearDownAll(() async {
    try {
      await tsnet.close();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  test('start connects and reaches Running state', () async {
    // start() returns only when the node is Running — no polling needed.
    await tsnet.start(
      nodeName: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: controlUrl,
      timeout: const Duration(seconds: 60),
    );

    expect(tsnet.isRunning, isTrue);
    expect(tsnet.proxyPort, greaterThan(0));
  });

  test('status returns our Tailscale IP', () async {
    final s = await tsnet.status();

    expect(s.isRunning, isTrue);
    expect(s.ipv4, startsWith('100.'));
  });

  test('status.onlinePeers returns a list', () async {
    final s = await tsnet.status();
    expect(s.onlinePeers, isA<List<PeerStatus>>());
  });

  test('http client is available', () async {
    expect(tsnet.http, isA<http.Client>());
  });

  test('close shuts down cleanly', () async {
    await tsnet.close();
    expect(tsnet.isRunning, isFalse);
  });

  test('restart and close + delete stateDir clears state', () async {
    await tsnet.start(
      nodeName: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: controlUrl,
      timeout: const Duration(seconds: 60),
    );

    await tsnet.close();
    Directory(stateDir).deleteSync(recursive: true);

    expect(tsnet.isRunning, isFalse);
    expect(Directory(stateDir).existsSync(), isFalse);
  });
}
