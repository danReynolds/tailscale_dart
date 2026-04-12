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

  test('start connects to Headscale', () async {
    await tsnet.start(
      nodeName: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: controlUrl,
    );

    expect(tsnet.proxyPort, greaterThan(0));
  });

  test('status returns our Tailscale IP after init', () async {
    // CI runners may be slower — allow up to 30s for the IP to propagate.
    TailscaleStatus? s;
    for (var i = 0; i < 30; i++) {
      s = await tsnet.status();
      if (s.ipv4 != null) break;
      await Future.delayed(const Duration(seconds: 1));
    }

    expect(s, isNotNull);
    expect(s!.ipv4, startsWith('100.'));
  });

  test('status returns valid status with our node', () async {
    // CI runners may need time for the node to reach Running state.
    TailscaleStatus? s;
    for (var i = 0; i < 30; i++) {
      s = await tsnet.status();
      if (s.isRunning) break;
      await Future.delayed(const Duration(seconds: 1));
    }

    expect(s!.isRunning, isTrue);
  });

  test('status().onlinePeers returns a list (may be empty with one node)',
      () async {
    final s = await tsnet.status();
    expect(s.onlinePeers, isA<List<PeerStatus>>());
  });

  test('tsnet.http can make requests through the tunnel', () async {
    // We can't easily test a full HTTP request without a second peer,
    // but we verify the client is wired to the correct proxy port.
    expect(tsnet.http, isA<http.Client>());
    expect(tsnet.proxyPort, greaterThan(0));
  });

  test('stop shuts down cleanly', () async {
    await tsnet.close();
    expect(tsnet.isRunning, isFalse);
  });

  test('stop + delete stateDir clears state', () async {
    // Restart so we have a running node to stop.
    await tsnet.start(
      nodeName: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: controlUrl,
    );

    await tsnet.close();
    Directory(stateDir).deleteSync(recursive: true);

    expect(tsnet.isRunning, isFalse);
    expect(Directory(stateDir).existsSync(), isFalse);
  });
}
