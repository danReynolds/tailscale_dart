/// End-to-end test against a real Headscale control server.
///
/// Run via: test/e2e/run_e2e.sh (handles Docker setup and teardown).
///
/// Required environment variables:
///   HEADSCALE_URL      - e.g. http://localhost:8080
///   HEADSCALE_AUTH_KEY  - pre-auth key from headscale
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
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
    await tsnet.up(
      hostname: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: Uri.parse(controlUrl),
    );

    // up() starts the node — wait for it to reach Running via state stream.
    await tsnet.onStateChange
        .firstWhere((s) => s == NodeState.running)
        .timeout(const Duration(seconds: 30));

    final status = await tsnet.status();
    expect(status.ipv4, startsWith('100.'));
  });

  test('status returns current state', () async {
    final s = await tsnet.status();
    expect(s.ipv4, startsWith('100.'));
  });

  test('peers returns a list', () async {
    final peers = await tsnet.peers();
    expect(peers, isA<List<PeerStatus>>());
  });

  test('http client is available', () async {
    expect(tsnet.http, isA<http.Client>());
  });

  group('two-node connectivity', () {
    late Process peer;
    late String peerStateDir;
    late String peerIpv4;
    final peerResponseBody = 'hello from peer ${DateTime.now().microsecondsSinceEpoch}';

    setUpAll(() async {
      peerStateDir =
          Directory.systemTemp.createTempSync('tailscale_e2e_peer_').path;

      peer = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          '--enable-experiment=native-assets',
          'test/e2e/peer_main.dart',
        ],
        environment: {
          ...Platform.environment,
          'STATE_DIR': peerStateDir,
          'CONTROL_URL': controlUrl,
          'AUTH_KEY': authKey,
          'HOSTNAME': 'dune-e2e-peer',
          'RESPONSE_BODY': peerResponseBody,
        },
      );

      // Forward peer stderr so failures are debuggable.
      unawaited(peer.stderr
          .transform(utf8.decoder)
          .forEach((chunk) => stderr.write('[peer stderr] $chunk')));

      final ready = Completer<String>();
      final readyRegex = RegExp(r'READY\s+(\S+)');
      unawaited(peer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        stdout.writeln('[peer] $line');
        final match = readyRegex.firstMatch(line);
        if (match != null && !ready.isCompleted) {
          ready.complete(match.group(1)!);
        }
      }));

      peerIpv4 = await ready.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          peer.kill(ProcessSignal.sigterm);
          throw StateError('peer did not become ready within 90s');
        },
      );
    });

    tearDownAll(() async {
      try {
        await peer.stdin.close();
        await peer.exitCode.timeout(const Duration(seconds: 15));
      } catch (_) {
        peer.kill(ProcessSignal.sigterm);
      }
      try {
        Directory(peerStateDir).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('peer appears in peers()', () async {
      PeerStatus? match;
      for (var i = 0; i < 30; i++) {
        final peers = await tsnet.peers();
        try {
          match = peers.firstWhere((p) => p.ipv4 == peerIpv4);
          break;
        } on StateError {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      expect(match, isNotNull, reason: 'peer $peerIpv4 never appeared in peers()');
      expect(match!.online, isTrue);
    });

    test('http.get reaches peer via tailnet', () async {
      final resp = await tsnet.http
          .get(Uri.parse('http://$peerIpv4/hello'))
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200);
      expect(resp.body, peerResponseBody);
    });
  });

  test('down shuts down cleanly', () async {
    await tsnet.down();
  });

  test('logout clears persisted state', () async {
    await tsnet.up(
      hostname: 'dune-e2e-test',
      authKey: authKey,
      controlUrl: Uri.parse(controlUrl),
    );

    await tsnet.logout();

    expect(Directory(stateDir).existsSync(), isTrue);
    expect(Directory(p.join(stateDir, 'tailscale')).existsSync(), isFalse);
  });
}
