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
import 'package:path/path.dart' as p;
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
      await tsnet.down();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  test('up connects and reaches Running state', () async {
    // up() returns the current status once the node is Running.
    final status = await tsnet.up(
      hostname: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: Uri.parse(controlUrl),
      timeout: const Duration(seconds: 60),
    );

    expect(tsnet.isRunning, isTrue);
    expect(status.isRunning, isTrue);
    expect(status.ipv4, startsWith('100.'));
    expect(tsnet.proxyPort, greaterThan(0));
  });

  test('status returns our Tailscale IP', () async {
    final s = await tsnet.status();

    expect(s.isRunning, isTrue);
    expect(s.ipv4, startsWith('100.'));
  });

  test('peers returns a list', () async {
    final peers = await tsnet.peers();
    expect(peers, isA<List<PeerStatus>>());
  });

  test('http client is available', () async {
    expect(tsnet.httpClient, isA<http.Client>());
  });

  test('down shuts down cleanly', () async {
    await tsnet.down();
    expect(tsnet.isRunning, isFalse);
  });

  test('logout clears persisted state', () async {
    await tsnet.up(
      hostname: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: Uri.parse(controlUrl),
      timeout: const Duration(seconds: 60),
    );

    await tsnet.logout();

    expect(tsnet.isRunning, isFalse);
    expect(Directory(stateDir).existsSync(), isTrue);
    expect(Directory(p.join(stateDir, 'tailscale')).existsSync(), isFalse);
  });
}
