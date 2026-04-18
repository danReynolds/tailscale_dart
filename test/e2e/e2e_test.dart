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
    //
    // TODO: remove this workaround once we're on a Dart stable that
    // includes the upstream fix. Tracked in dart-lang/native#2921; fix
    // merged on `main` 2026-01-07 as dart-lang/sdk@3e020921 ("[dartdev]
    // Delete and create dylibs instead of truncate") but is not in Dart
    // 3.11.5. Expected to ship with Dart 3.12+.
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

  test('up connects and reaches Running through Starting', () async {
    // Records the full emitted sequence (not just the Running terminal) so
    // we catch skipped intermediates. Contract from `Tailscale.up` docs:
    // a fresh login goes through `starting` on its way to `running`.
    final sequence = await _recordUntil(
      tsnet,
      NodeState.running,
      () => tsnet.up(
        hostname: 'dune-e2e-test',
        authKey: authKey,
        controlUrl: Uri.parse(controlUrl),
      ),
      timeout: const Duration(seconds: 30),
    );

    expect(
      sequence,
      containsAllInOrder([NodeState.starting, NodeState.running]),
      reason:
          'a fresh up() must emit Starting before Running — skipping '
          'Starting leaves UI subscribers without the "connecting" state',
    );

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

  // Every transition that the lifecycle APIs promise in docs, verified end
  // to end through `onStateChange`. Subscribers that mirror state via this
  // stream (e.g. Dart app layers that bind UI routing to the engine's
  // state) depend on every documented transition actually firing — a
  // missed emit leaves their mirror stuck and the UI goes out of sync.
  //
  // Assertion flavor per transition:
  //   - `up()` paths (watcher attached with `NotifyInitialState` before the
  //     engine reaches Running) assert ordered `Starting → Running` via
  //     `containsAllInOrder`. Any leading/intermediate state the watcher
  //     catches between attach and Running is tolerated, but `NoState` /
  //     `Stopped` mid-flight are banned — they'd imply the engine lost
  //     creds or tore itself down.
  //   - `down()` / `logout()` paths disable the IPN watcher before the
  //     synthetic publish, so the emitted sequence is fully deterministic
  //     and asserted with `equals` (exact match).
  //
  // Placed at the end of the file because the logout tests wipe persisted
  // state and would break earlier tests that assume an up, authenticated
  // node. Each test inside attaches its stream listener BEFORE triggering
  // the transition (see [_recordUntil]) so events can't slip past, and
  // each test normalizes its entry state so the group is safe under
  // reordering.
  group('onStateChange lifecycle', () {
    test('up emits Starting → Running with a fresh auth key', () async {
      await tsnet.down();

      final sequence = await _recordUntil(
        tsnet,
        NodeState.running,
        () => tsnet.up(
          hostname: 'dune-e2e-state-running',
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        ),
      );

      expect(
        sequence,
        containsAllInOrder([NodeState.starting, NodeState.running]),
        reason:
            'up() with an auth key must surface Starting before Running so '
            'UI subscribers can show a "connecting" state',
      );
      expect(
        sequence,
        isNot(contains(NodeState.noState)),
        reason:
            'a login with an auth key should not dip through NoState mid-'
            'flight — that would tell UI subscribers the node has no creds',
      );
      expect(
        sequence,
        isNot(contains(NodeState.stopped)),
        reason: 'up() must not emit Stopped mid-flight — the node is coming '
            'online, not shutting down',
      );
      expect((await tsnet.status()).state, NodeState.running);
    });

    test('down emits exactly [Stopped] after Running', () async {
      if ((await tsnet.status()).state != NodeState.running) {
        await _recordUntil(
          tsnet,
          NodeState.running,
          () => tsnet.up(
            hostname: 'dune-e2e-state-down-setup',
            authKey: authKey,
            controlUrl: Uri.parse(controlUrl),
          ),
        );
      }

      final sequence = await _recordUntil(
        tsnet,
        NodeState.stopped,
        () => tsnet.down(),
      );

      // The worker cancels the IPN watcher before calling Stop(), so the
      // only event that reaches subscribers is the synthetic Stopped emit
      // from go/lib.go's Stop().
      expect(
        sequence,
        equals([NodeState.stopped]),
        reason:
            'down() should produce exactly one emit — the synthetic '
            'Stopped from Stop(). Any extra events indicate the IPN '
            'watcher is leaking transitions across the teardown boundary.',
      );
      expect((await tsnet.status()).state, NodeState.stopped);
    });

    test(
      'up after down emits Starting → Running via persisted credentials',
      () async {
        if ((await tsnet.status()).state == NodeState.running) {
          await _recordUntil(
            tsnet, NodeState.stopped, () => tsnet.down());
        }
        expect(
          (await tsnet.status()).state,
          NodeState.stopped,
          reason:
              'need `stopped` entry state so the reconnect-without-authkey '
              'path is what we exercise here',
        );

        final sequence = await _recordUntil(
          tsnet,
          NodeState.running,
          () => tsnet.up(
            hostname: 'dune-e2e-state-reconnect',
            controlUrl: Uri.parse(controlUrl),
          ),
        );

        expect(
          sequence,
          containsAllInOrder([NodeState.starting, NodeState.running]),
          reason:
              'a reconnect must still transition through Starting — same '
              'UI contract as a fresh login',
        );
        expect(
          sequence,
          isNot(contains(NodeState.noState)),
          reason:
              'a reconnect with persisted credentials must never emit '
              'NoState — that would imply the engine lost its creds',
        );
        expect(
          sequence,
          isNot(contains(NodeState.stopped)),
          reason: 'mid-flight Stopped during up() would suggest the engine '
              'bounced — not expected on a clean reconnect',
        );
        expect((await tsnet.status()).state, NodeState.running);
      },
    );

    test('down is silent when already stopped (wasRunning guard)', () async {
      if ((await tsnet.status()).state == NodeState.running) {
        await _recordUntil(tsnet, NodeState.stopped, () => tsnet.down());
      }

      final emits = <NodeState>[];
      final sub = tsnet.onStateChange.listen(emits.add);

      await tsnet.down();
      // Give the worker→main isolate channel a window to deliver any
      // (phantom) event before we assert it didn't happen.
      await Future<void>.delayed(const Duration(seconds: 1));
      await sub.cancel();

      expect(
        emits,
        isEmpty,
        reason:
            'Stop() in go/lib.go only publishes Stopped when wasRunning '
            '(srv != nil); a no-op down() must not reach subscribers — '
            'otherwise cross-lifecycle subscribers see phantom emits',
      );
    });

    test('onStateChange is a broadcast stream delivering to all subscribers',
        () async {
      if ((await tsnet.status()).state == NodeState.running) {
        await _recordUntil(tsnet, NodeState.stopped, () => tsnet.down());
      }

      final a = <NodeState>[];
      final b = <NodeState>[];
      final aSawRunning = Completer<void>();
      final bSawRunning = Completer<void>();

      final subA = tsnet.onStateChange.listen((s) {
        a.add(s);
        if (s == NodeState.running && !aSawRunning.isCompleted) {
          aSawRunning.complete();
        }
      });
      final subB = tsnet.onStateChange.listen((s) {
        b.add(s);
        if (s == NodeState.running && !bSawRunning.isCompleted) {
          bSawRunning.complete();
        }
      });

      try {
        await tsnet.up(
          hostname: 'dune-e2e-state-broadcast',
          controlUrl: Uri.parse(controlUrl),
        );
        await Future.wait([aSawRunning.future, bSawRunning.future])
            .timeout(const Duration(seconds: 10));
      } finally {
        await subA.cancel();
        await subB.cancel();
      }

      // Both subscribers attached BEFORE up(), so both must have
      // captured the Running event — proves broadcast delivery.
      expect(a, contains(NodeState.running));
      expect(b, contains(NodeState.running));
    });

    test(
      'logout from running emits exactly [Stopped, NoState] and clears creds',
      () async {
        if ((await tsnet.status()).state != NodeState.running) {
          await _recordUntil(
            tsnet,
            NodeState.running,
            () => tsnet.up(
              hostname: 'dune-e2e-state-logout-setup',
              authKey: authKey,
              controlUrl: Uri.parse(controlUrl),
            ),
          );
        }

        final sequence = await _recordUntil(
          tsnet,
          NodeState.noState,
          () => tsnet.logout(),
        );

        // IPN watcher is cancelled before Stop(); only the two synthetic
        // publishes reach subscribers, and in this order.
        expect(
          sequence,
          equals([NodeState.stopped, NodeState.noState]),
          reason:
              'logout from a running node must emit exactly Stopped then '
              'NoState — Stop() publishes Stopped on teardown and Logout() '
              'publishes NoState after wiping creds. Subscribers rely on '
              'this full sequence to route back to the unauthenticated UI.',
        );
        expect((await tsnet.status()).state, NodeState.noState);

        expect(
          Directory(p.join(stateDir, 'tailscale')).existsSync(),
          isFalse,
          reason:
              'logout() should remove the persisted tailscale state subdir',
        );
      },
    );

    test('logout from stopped emits exactly [NoState] (no phantom Stopped)',
        () async {
      // Re-establish creds (prior test wiped them) and go to stopped.
      await _recordUntil(
        tsnet,
        NodeState.running,
        () => tsnet.up(
          hostname: 'dune-e2e-state-logout-from-stopped',
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        ),
      );
      await _recordUntil(tsnet, NodeState.stopped, () => tsnet.down());

      final sequence = await _recordUntil(
        tsnet,
        NodeState.noState,
        () => tsnet.logout(),
      );

      expect(
        sequence,
        equals([NodeState.noState]),
        reason:
            "logout from an already-stopped node must not emit Stopped — "
            "Stop()'s wasRunning guard skips the publish when srv is nil, "
            'so the full sequence is just NoState',
      );
      expect((await tsnet.status()).state, NodeState.noState);
    });
  });
}

/// Records every [NodeState] emitted on `onStateChange` while [action] runs,
/// stopping once [terminal] is observed. Attaches the listener *before*
/// invoking [action] so events can't slip past due to subscription timing.
///
/// Times out with a [TimeoutException] that includes the partial sequence —
/// the partial is load-bearing when debugging a stuck transition ("we
/// emitted Starting but never Running" is a very different failure from "we
/// never emitted anything").
Future<List<NodeState>> _recordUntil(
  Tailscale tsnet,
  NodeState terminal,
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final sequence = <NodeState>[];
  final done = Completer<void>();

  final sub = tsnet.onStateChange.listen((s) {
    sequence.add(s);
    if (s == terminal && !done.isCompleted) done.complete();
  });

  try {
    await action();
    await done.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'onStateChange never emitted $terminal; '
        'got [${sequence.join(' → ')}]',
      ),
    );
    return sequence;
  } finally {
    await sub.cancel();
  }
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
