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
import 'dart:typed_data';

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
    );

    expect(
      sequence,
      containsAllInOrder([NodeState.starting, NodeState.running]),
      reason: 'a fresh up() must emit Starting before Running — skipping '
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
    expect(tsnet.http.client, isA<http.Client>());
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
      final resp = await tsnet.http.client
          .get(Uri.parse('http://${peer.ipv4}/hello'))
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200);
      expect(resp.body, peerResponseBody);
    });

    test('http.post sends body through the tailnet', () async {
      final resp = await tsnet.http.client
          .post(
            Uri.parse('http://${peer.ipv4}/echo'),
            headers: {'content-type': 'text/plain'},
            body: 'ping-from-node-a',
          )
          .timeout(const Duration(seconds: 30));
      expect(resp.statusCode, 200);
      expect(resp.body, 'echo: ping-from-node-a');
    });

    test('tcp.dial reaches the peer echo server and round-trips bytes',
        () async {
      final socket = await tsnet.tcp
          .dial(peer.ipv4, 7000, timeout: const Duration(seconds: 30))
          .timeout(const Duration(seconds: 30));

      try {
        final payload =
            utf8.encode('tcp-echo-${DateTime.now().microsecondsSinceEpoch}');
        socket.add(payload);
        await socket.flush();

        final received = BytesBuilder();
        await for (final chunk in socket.timeout(
          const Duration(seconds: 15),
          onTimeout: (sink) => sink.close(),
        )) {
          received.add(chunk);
          if (received.length >= payload.length) break;
        }
        expect(received.takeBytes(), payload);
      } finally {
        await socket.close();
      }
    });

    test('tcp.dial round-trips a 1 MiB payload end-to-end', () async {
      final socket = await tsnet.tcp
          .dial(peer.ipv4, 7000, timeout: const Duration(seconds: 30))
          .timeout(const Duration(seconds: 30));

      try {
        const payloadSize = 1 << 20; // 1 MiB
        final payload = Uint8List(payloadSize);
        for (var i = 0; i < payloadSize; i++) {
          payload[i] = (i * 37 + 11) & 0xff; // pseudo-random, reproducible
        }

        // Fire the write off without awaiting; the echo will start
        // flowing back immediately and we need to drain it concurrently
        // or the peer's send buffer fills and deadlocks.
        final writeDone = () async {
          socket.add(payload);
          await socket.flush();
          await socket.close(); // half-close signal — peer stops reading
        }();

        final received = BytesBuilder();
        await for (final chunk in socket.timeout(
          const Duration(seconds: 60),
          onTimeout: (sink) => sink.close(),
        )) {
          received.add(chunk);
          if (received.length >= payloadSize) break;
        }
        await writeDone;

        expect(received.length, payloadSize);
        final got = received.takeBytes();
        // Spot-check rather than full-equality so a mismatch message
        // doesn't dump a megabyte of hex.
        for (final i in [0, 1, payloadSize ~/ 2, payloadSize - 1]) {
          expect(got[i], payload[i], reason: 'byte at offset $i');
        }
      } finally {
        await socket.close();
      }
    });

    test('whois(peer.ipv4) returns the peer identity', () async {
      final identity = await tsnet.whois(peer.ipv4);
      expect(identity, isNotNull);
      expect(identity!.hostName, peer.hostname);
      expect(identity.nodeId, isNotEmpty);
      expect(identity.tailscaleIPs, contains(peer.ipv4));
    });

    test('whois returns null for an IP not on the tailnet', () async {
      final identity = await tsnet.whois('100.127.255.254');
      expect(identity, isNull);
    });

    test('onPeersChange emits while peers are online', () async {
      for (var i = 0; i < 30; i++) {
        final peers = await tsnet.peers();
        if (peers.any((p) => p.ipv4 == peer.ipv4)) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      final first =
          await tsnet.onPeersChange.first.timeout(const Duration(seconds: 2));
      expect(first, isNotEmpty);
      expect(first.any((p) => p.ipv4 == peer.ipv4), isTrue);
    });

    test('diag.ping reaches the peer', () async {
      final result = await tsnet.diag
          .ping(peer.ipv4, timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 15));
      expect(result.latency, greaterThan(Duration.zero));
    });

    test('diag.ping resolves MagicDNS hostnames', () async {
      final result = await tsnet.diag
          .ping(peer.hostname, timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 15));
      expect(result.latency, greaterThan(Duration.zero));
    });

    test('diag.metrics returns Prometheus-format text', () async {
      final metrics = await tsnet.diag.metrics();
      expect(metrics, isNotEmpty);
      // Prometheus scrapes always start with `# HELP` / `# TYPE`
      // comment lines, or at minimum contain a metric_name counter.
      expect(metrics, anyOf(contains('# HELP'), contains('# TYPE')));
    });

    test('diag.derpMap returns at least one region', () async {
      final map = await tsnet.diag.derpMap();
      expect(map.regions, isNotEmpty);
      final first = map.regions.values.first;
      expect(first.regionCode, isNotEmpty);
    });

    test('diag.checkUpdate returns without throwing', () async {
      // Either null (already on latest, or Headscale doesn't advertise
      // a newer version) or a populated ClientVersion. Anything else
      // would be a contract violation.
      final result = await tsnet.diag.checkUpdate();
      if (result != null) {
        expect(result.latestVersion, isNotEmpty);
      }
    });

    test('tls.domains returns a list (empty on Headscale)', () async {
      final domains = await tsnet.tls.domains();
      // Headscale doesn't provision certs, so this is expected empty.
      // The important thing is no exception.
      expect(domains, isA<List<String>>());
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

  // Every transition the lifecycle APIs promise in docs, verified end to
  // end through `onStateChange`. Subscribers that mirror state via this
  // stream (e.g. Dart app layers binding UI routing to engine state) depend
  // on every documented transition actually firing — a missed emit leaves
  // their mirror stuck and the UI goes out of sync.
  //
  // Two assertion flavors, matching what the implementation produces:
  //   - `up()` paths: the IPN watcher attaches with `NotifyInitialState`
  //     after `duneStart` kicks the engine, so the first observed event is
  //     whatever state the engine is in at attach time (empirically
  //     `NoState` for tsnet.Server, sometimes `NeedsLogin` on a truly
  //     empty state dir) followed by the natural Starting→Running
  //     progression. Assertions use `containsAllInOrder([starting,
  //     running])` — the leading state the watcher catches is a tsnet
  //     implementation detail and doesn't belong in the test contract.
  //   - `down()` / `logout()` paths cancel the IPN watcher before the
  //     synthetic publish, so the sequence is fully deterministic and
  //     asserted with `equals` (exact match).
  //
  // [setUp] normalizes every test to enter with the engine `stopped`,
  // credentials on disk, and no in-flight stream events. Test bodies then
  // read linearly — arrange, act, assert — with no defensive preambles.
  //
  // Placed at the end of the file because the logout tests wipe persisted
  // state; setUp re-establishes them for the next test, but earlier
  // groups outside this one can't rely on that repair.
  group('onStateChange lifecycle', () {
    const hostname = 'dune-e2e-lifecycle';
    Future<void> bringUp() => tsnet.up(
          hostname: hostname,
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        );
    Future<void> reconnect() => tsnet.up(
          hostname: hostname,
          controlUrl: Uri.parse(controlUrl),
        );

    setUp(() async {
      // Route each normalization transition through [_recordUntil] so its
      // events are captured by setUp's subscription instead of leaking
      // into the test's subscription.
      switch ((await tsnet.status()).state) {
        case NodeState.noState:
          // Logout wiped creds. Re-establish and shut down.
          await _recordUntil(tsnet, NodeState.running, bringUp);
          await _recordUntil(tsnet, NodeState.stopped, tsnet.down);
        case NodeState.running:
          await _recordUntil(tsnet, NodeState.stopped, tsnet.down);
        case NodeState.stopped:
          break;
        case final unexpected:
          fail('unexpected entry state for lifecycle setUp: $unexpected');
      }
    });

    test('up with auth key emits Starting → Running', () async {
      final sequence = await _recordUntil(tsnet, NodeState.running, bringUp);

      expect(
        sequence,
        containsAllInOrder([NodeState.starting, NodeState.running]),
        reason: 'UI subscribers depend on Starting to show a "connecting" '
            'state before Running',
      );
      expect((await tsnet.status()).state, NodeState.running);
    });

    test('down from running emits [Stopped]', () async {
      await _recordUntil(tsnet, NodeState.running, bringUp);

      final sequence = await _recordUntil(tsnet, NodeState.stopped, tsnet.down);

      expect(
        sequence,
        equals([NodeState.stopped]),
        reason: 'down() should emit exactly the synthetic Stopped from '
            'Stop(); extra events mean the IPN watcher is leaking '
            'transitions across the teardown boundary',
      );
      expect((await tsnet.status()).state, NodeState.stopped);
    });

    test('up without auth key reconnects via persisted credentials', () async {
      final sequence = await _recordUntil(tsnet, NodeState.running, reconnect);

      expect(
        sequence,
        containsAllInOrder([NodeState.starting, NodeState.running]),
        reason: 'reconnect must still transition through Starting — same '
            'UI contract as a fresh login',
      );
      expect((await tsnet.status()).state, NodeState.running);
    });

    test('down from stopped is silent (wasRunning guard)', () async {
      final emits = <NodeState>[];
      final sub = tsnet.onStateChange.listen(emits.add);

      await tsnet.down();
      // Give any (phantom) state event time to round-trip through the
      // worker→main isolate channel before asserting absence.
      await Future<void>.delayed(const Duration(seconds: 1));
      await sub.cancel();

      expect(
        emits,
        isEmpty,
        reason: 'Stop() only publishes when wasRunning (srv != nil); a '
            'no-op down() must not reach subscribers',
      );
    });

    test('onStateChange delivers to multiple subscribers (broadcast)',
        () async {
      // Two independent `firstWhere` subscriptions attached before the
      // transition. Each creates its own listener on the stream; on a
      // non-broadcast stream the second would throw `Bad state: Stream
      // has already been listened to`. If they both resolve, both
      // subscribers saw Running — i.e. broadcast delivery works.
      final bothSawRunning = Future.wait([
        tsnet.onStateChange.firstWhere((s) => s == NodeState.running),
        tsnet.onStateChange.firstWhere((s) => s == NodeState.running),
      ]);

      await reconnect();
      await bothSawRunning.timeout(const Duration(seconds: 10));
    });

    test('logout from running emits [Stopped, NoState] and clears creds',
        () async {
      await _recordUntil(tsnet, NodeState.running, bringUp);

      final sequence =
          await _recordUntil(tsnet, NodeState.noState, tsnet.logout);

      expect(
        sequence,
        equals([NodeState.stopped, NodeState.noState]),
        reason: 'logout from running must emit Stopped then NoState — '
            'Stop() publishes Stopped on teardown, Logout() publishes '
            'NoState after wiping creds. Subscribers rely on this full '
            'sequence to route back to the unauthenticated UI.',
      );
      expect((await tsnet.status()).state, NodeState.noState);
      expect(
        Directory(p.join(stateDir, 'tailscale')).existsSync(),
        isFalse,
        reason: 'logout() should remove the persisted tailscale state subdir',
      );
    });

    test('logout from stopped emits [NoState] (no phantom Stopped)', () async {
      final sequence =
          await _recordUntil(tsnet, NodeState.noState, tsnet.logout);

      expect(
        sequence,
        equals([NodeState.noState]),
        reason: "logout from stopped must not emit Stopped — Stop()'s "
            'wasRunning guard skips the publish when srv is nil',
      );
      expect((await tsnet.status()).state, NodeState.noState);
    });

    // Consecutive-duplicate scenarios — the stream filters these via
    // `Stream.distinct` in [Tailscale.onStateChange]. Each test attaches a
    // single subscription across two transitions so the filter's internal
    // "previous" state carries over; a single subscription on a fresh
    // distinct stream would only see the second event and wouldn't prove
    // the filter fired.

    test('up() while already running does not re-emit Running', () async {
      var runningCount = 0;
      final sub = tsnet.onStateChange.listen((s) {
        if (s == NodeState.running) runningCount++;
      });

      // First up — real transition, emits Running.
      await _recordUntil(tsnet, NodeState.running, bringUp);
      // Second up without an auth key — Go's Start returns early (srv
      // != nil, authKey == ""), but the worker still runs
      // duneStopWatch + duneStartWatch. The new watcher's
      // NotifyInitialState re-emits Running, which onStateChange
      // deduplicates.
      await reconnect();
      await Future<void>.delayed(const Duration(seconds: 1));
      await sub.cancel();

      expect(
        runningCount,
        1,
        reason: 'a no-op up() must not surface a second Running to the '
            'stream — distinct() filters the watcher reattach duplicate',
      );
    });

    test('logout() twice does not re-emit NoState', () async {
      // Bring up *before* subscribing so the IPN watcher's initial
      // NoState emit (during engine startup) doesn't show up in our
      // count — we want to isolate the logout emits.
      await _recordUntil(tsnet, NodeState.running, bringUp);

      var noStateCount = 0;
      final sub = tsnet.onStateChange.listen((s) {
        if (s == NodeState.noState) noStateCount++;
      });

      // First logout — emits Stopped then NoState. Both pass (different
      // from each other; _previous starts at null for this fresh
      // distinct stream).
      await _recordUntil(tsnet, NodeState.noState, tsnet.logout);

      // Second logout — srv already nil (wasRunning guard skips Stop's
      // Stopped publish), state dir already gone, but Logout still
      // calls publishState("NoState"). distinct() filters the duplicate
      // because _previous is NoState from the first logout.
      await tsnet.logout();
      await Future<void>.delayed(const Duration(seconds: 1));
      await sub.cancel();

      expect(
        noStateCount,
        1,
        reason: 'a redundant logout() must not surface a second NoState — '
            'distinct() filters publishState("NoState") when it matches '
            'the most recently emitted state',
      );
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
///
/// Default 30s because the up paths wait on real network round-trips to
/// Headscale (first-boot auth can be the slow leg on CI runners). The
/// terminal-state paths (Stopped, NoState) are synthetic and nearly
/// instant, so the extra headroom costs nothing when the test succeeds.
Future<List<NodeState>> _recordUntil(
  Tailscale tsnet,
  NodeState terminal,
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 30),
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
  _PeerProcess._(this._process, this.ipv4, this.hostname);

  final Process _process;
  final String ipv4;
  final String hostname;

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
    return _PeerProcess._(process, ipv4, hostname);
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
