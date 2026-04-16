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

  setUpAll(() async {
    // Warm up the package's native build hook by invoking peer_main.dart
    // once with PEER_WARMUP=1 (it exits immediately). This populates the
    // hook framework's cache and materializes
    // .dart_tool/lib/libtailscale.so before this process tries to mmap it.
    final warmup = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--enable-experiment=native-assets',
        'test/e2e/peer_main.dart',
      ],
      environment: {
        ...Platform.environment,
        'PEER_WARMUP': '1',
      },
    );
    if (warmup.exitCode != 0) {
      throw StateError(
        'Peer warmup failed (exit ${warmup.exitCode})\n'
        'stdout: ${warmup.stdout}\nstderr: ${warmup.stderr}',
      );
    }

    // Load the .so via FFI in this process.
    stateDir = Directory.systemTemp.createTempSync('tailscale_e2e_').path;
    Tailscale.init(stateDir: stateDir);
    tsnet = Tailscale.instance;

    // Detach the loaded .so from its directory entry so subsequent
    // subprocess `dart run` invocations can't crash this process.
    //
    // The Dart hooks framework re-copies the cached
    // .so → .dart_tool/lib/libtailscale.so on every `dart run`,
    // truncating and rewriting the existing inode in place. On Linux,
    // overwriting an mmap'd file kills mappers with SIGBUS. We can't
    // change the framework, so we rename a freshly-copied sibling over
    // the original: the directory entry now points to a NEW inode, the
    // kernel keeps the OLD inode (which we have mmap'd) alive until we
    // exit, and any future framework copy hits the new inode without
    // touching our mapping.
    if (Platform.isLinux) {
      const libPath = '.dart_tool/lib/libtailscale.so';
      final detachedPath = '$libPath.detached';
      final cp = await Process.run('cp', ['-f', libPath, detachedPath]);
      if (cp.exitCode != 0) {
        throw StateError('cp failed: ${cp.stderr}');
      }
      final mv = await Process.run('mv', [detachedPath, libPath]);
      if (mv.exitCode != 0) {
        throw StateError('mv failed: ${mv.stderr}');
      }
    }
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

  // Two-node groups spawn `dart run test/e2e/peer_main.dart` as a subprocess.
  // On Linux CI runners the Dart hooks framework re-invokes the package's
  // native build hook from the subprocess, which races the parent process's
  // mmap of the .so and crashes the parent with SIGBUS. The library itself
  // works fine on Linux — the issue is in the test harness's subprocess
  // pattern. Currently un-skipped while diagnosing; the CI workflow dumps
  // /tmp/dune_hook.log on failure (DUNE_HOOK_LOG=1 is set in env).
  group('two-node connectivity', () {
    late _PeerProcess peer;
    late String peerStateDir;
    final peerResponseBody =
        'hello from peer ${DateTime.now().microsecondsSinceEpoch}';

    setUpAll(() async {
      peerStateDir =
          Directory.systemTemp.createTempSync('tailscale_e2e_peer_').path;
      peer = await _PeerProcess.spawn(
        stateDir: peerStateDir,
        controlUrl: controlUrl,
        authKey: authKey,
        hostname: 'dune-e2e-peer',
        responseBody: peerResponseBody,
      );
    });

    tearDownAll(() async {
      await peer.shutdown();
      try {
        Directory(peerStateDir).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('peer appears in peers()', () async {
      PeerStatus? match;
      for (var i = 0; i < 30; i++) {
        final peers = await tsnet.peers();
        try {
          match = peers.firstWhere((p) => p.ipv4 == peer.ipv4);
          break;
        } on StateError {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      expect(match, isNotNull,
          reason: 'peer ${peer.ipv4} never appeared in peers()');
      expect(match!.online, isTrue);
    });

    test('http.get reaches peer via tailnet', () async {
      final resp = await tsnet.http
          .get(Uri.parse('http://${peer.ipv4}/hello'))
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200);
      expect(resp.body, peerResponseBody);
    });

    test('http.post sends body through the tailnet', () async {
      final resp = await tsnet.http
          .post(
            Uri.parse('http://${peer.ipv4}/echo'),
            headers: {'content-type': 'text/plain'},
            body: 'ping-from-node-a',
          )
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200);
      expect(resp.body, 'echo: ping-from-node-a');
    });
  });

  group('peer reconnects with persisted credentials', () {
    late String persistStateDir;
    String? firstIpv4;

    setUpAll(() {
      persistStateDir =
          Directory.systemTemp.createTempSync('tailscale_e2e_persist_').path;
    });

    tearDownAll(() {
      try {
        Directory(persistStateDir).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('first launch registers and persists credentials', () async {
      final peer = await _PeerProcess.spawn(
        stateDir: persistStateDir,
        controlUrl: controlUrl,
        authKey: authKey,
        hostname: 'dune-e2e-persist',
      );
      firstIpv4 = peer.ipv4;
      await peer.shutdown();
      expect(
        Directory(p.join(persistStateDir, 'tailscale')).existsSync(),
        isTrue,
        reason: 'persisted state should remain on disk after shutdown',
      );
    });

    test('second launch reconnects without an authKey', () async {
      final peer = await _PeerProcess.spawn(
        stateDir: persistStateDir,
        controlUrl: controlUrl,
        // Deliberately no authKey — must come up from persisted state.
        hostname: 'dune-e2e-persist',
      );
      addTearDown(peer.shutdown);
      expect(peer.ipv4, firstIpv4,
          reason: 'reconnect should keep the same tailnet IPv4');
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

/// Handle to a `peer_main.dart` subprocess that has reached Running and
/// announced its tailnet IPv4.
class _PeerProcess {
  _PeerProcess._(this._process, this.ipv4);

  final Process _process;
  final String ipv4;

  static Future<_PeerProcess> spawn({
    required String stateDir,
    required String controlUrl,
    required String hostname,
    String? authKey,
    String? responseBody,
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '--enable-experiment=native-assets',
        'test/e2e/peer_main.dart',
      ],
      environment: {
        ...Platform.environment,
        'STATE_DIR': stateDir,
        'CONTROL_URL': controlUrl,
        'HOSTNAME': hostname,
        if (authKey != null) 'AUTH_KEY': authKey,
        if (responseBody != null) 'RESPONSE_BODY': responseBody,
      },
    );

    unawaited(process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => stderr.write('[peer stderr] $chunk')));

    final ready = Completer<String>();
    final readyRegex = RegExp(r'READY\s+(\S+)');
    unawaited(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      stdout.writeln('[peer $hostname] $line');
      final match = readyRegex.firstMatch(line);
      if (match != null && !ready.isCompleted) {
        ready.complete(match.group(1)!);
      }
    }));

    final ipv4 = await ready.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw StateError('peer "$hostname" did not become ready within 90s');
      },
    );
    return _PeerProcess._(process, ipv4);
  }

  /// Gracefully shut the peer down by closing its stdin; falls back to
  /// SIGTERM if it doesn't exit within 15 seconds.
  Future<void> shutdown() async {
    try {
      await _process.stdin.close();
      await _process.exitCode.timeout(const Duration(seconds: 15));
    } catch (_) {
      _process.kill(ProcessSignal.sigterm);
    }
  }
}
