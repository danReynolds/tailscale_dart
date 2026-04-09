/// End-to-end test against a real Headscale control server.
///
/// Run via: test/e2e/run_e2e.sh (handles Docker setup and teardown).
///
/// Required environment variables:
///   HEADSCALE_URL      - e.g. http://localhost:8080
///   HEADSCALE_AUTH_KEY  - pre-auth key from headscale
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

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

  late DuneTsnet tsnet;
  late String stateDir;

  setUpAll(() {
    stateDir = Directory.systemTemp.createTempSync('tailscale_e2e_').path;
    tsnet = DuneTsnet.instance;
  });

  tearDownAll(() async {
    try {
      await tsnet.stop();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  test('init connects to Headscale and returns a proxy port', () async {
    await tsnet.init(
      clientId: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: controlUrl,
      stateDir: stateDir,
    );

    expect(tsnet.proxyPort, greaterThan(0));
  });

  test('getLocalIP returns a Tailscale IP after init', () async {
    String? ip;
    for (var i = 0; i < 10; i++) {
      ip = await tsnet.getLocalIP();
      if (ip != null) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }

    expect(ip, isNotNull);
    expect(ip, startsWith('100.'));
  });

  test('getStatus returns valid JSON with our node', () async {
    final statusJson = await tsnet.getStatus();
    final status = jsonDecode(statusJson) as Map<String, dynamic>;

    expect(status, isNotEmpty);
    expect(status.containsKey('error'), isFalse);
  });

  test('getPeerAddresses returns a list (may be empty with one node)',
      () async {
    final peers = await tsnet.getPeerAddresses();
    expect(peers, isA<List<String>>());
  });

  test('isProvisioned returns true after init', () async {
    final provisioned = await tsnet.isProvisioned(stateDir);
    expect(provisioned, isTrue);
  });

  test('getProxyUri builds valid URI with the real port', () {
    final uri = tsnet.getProxyUri('100.64.0.1', '/api/test');

    expect(uri.port, tsnet.proxyPort);
    expect(uri.host, '127.0.0.1');
    expect(uri.path, '/api/test');
  });

  test('stop shuts down cleanly', () async {
    await tsnet.stop();
    expect(tsnet.proxyPort, 0);
  });

  test('isProvisioned still true after stop (state preserved)', () async {
    final provisioned = await tsnet.isProvisioned(stateDir);
    expect(provisioned, isTrue);
  });

  test('logout clears state', () async {
    await tsnet.logout(stateDir);

    expect(tsnet.proxyPort, 0);
    final provisioned = await tsnet.isProvisioned(stateDir);
    expect(provisioned, isFalse);
  });
}
