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

import 'support/native_asset_workaround.dart';
import 'support/peer_process.dart';
import 'support/state_waiters.dart';

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
    await warmUpNativeAssetForPeerSubprocesses();

    stateDir = Directory.systemTemp.createTempSync('tailscale_e2e_').path;
    Tailscale.init(stateDir: stateDir);
    tsnet = Tailscale.instance;
    await detachLoadedNativeAssetForPeerSubprocesses();
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
    final sequence = await recordUntil(
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

  test('nodes returns a list', () async {
    final nodes = await tsnet.nodes();
    expect(nodes, isA<List<TailscaleNode>>());
  });

  test('http client is available', () async {
    expect(tsnet.http.client, isA<http.Client>());
  });

  test('prefs writes round-trip through LocalAPI', () async {
    final original = await tsnet.prefs.get();
    addTearDown(() async {
      await tsnet.prefs.updateMasked(
        PrefsUpdate(
          advertisedRoutes: original.advertisedRoutes,
          acceptRoutes: original.acceptRoutes,
          shieldsUp: original.shieldsUp,
        ),
      );
    });

    var updated = await tsnet.prefs.setShieldsUp(!original.shieldsUp);
    expect(updated.shieldsUp, isNot(original.shieldsUp));

    updated = await tsnet.prefs.setAcceptRoutes(!original.acceptRoutes);
    expect(updated.acceptRoutes, isNot(original.acceptRoutes));

    updated = await tsnet.prefs.setAdvertisedRoutes(['10.77.0.0/24']);
    expect(updated.advertisedRoutes, contains('10.77.0.0/24'));

    updated = await tsnet.prefs.setAdvertisedRoutes(const []);
    expect(updated.advertisedRoutes, isEmpty);
  });

  // Two-node groups spawn `dart run test/e2e/peer_main.dart` as a subprocess.
  // On Linux CI runners the Dart hooks framework re-invokes the package's
  // native build hook from the subprocess, which races the parent process's
  // mmap of the .so and crashes the parent with SIGBUS. The library itself
  // works fine on Linux — the issue is in the test harness's subprocess
  // pattern. Currently un-skipped while diagnosing; the CI workflow dumps
  // /tmp/dune_hook.log on failure (DUNE_HOOK_LOG=1 is set in env).
  group('two-node connectivity', () {
    late PeerProcess peer;
    late String peerStateDir;
    final peerResponseBody =
        'hello from peer ${DateTime.now().microsecondsSinceEpoch}';

    setUpAll(() async {
      peerStateDir = Directory.systemTemp
          .createTempSync('tailscale_e2e_peer_')
          .path;
      peer = await PeerProcess.spawn(
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

    test('node appears in nodes()', () async {
      TailscaleNode? match;
      for (var i = 0; i < 30; i++) {
        final nodes = await tsnet.nodes();
        try {
          match = nodes.firstWhere((p) => p.ipv4 == peer.ipv4);
          break;
        } on StateError {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      expect(
        match,
        isNotNull,
        reason: 'node ${peer.ipv4} never appeared in nodes()',
      );
      expect(match!.online, isTrue);
    });

    test('nodeByIp resolves the node snapshot by Tailscale IP', () async {
      TailscaleNode? match;
      for (var i = 0; i < 30; i++) {
        match = await tsnet.nodeByIp(peer.ipv4);
        if (match != null) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(match, isNotNull);
      expect(match!.ipv4, peer.ipv4);
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

    test(
      'tcp.dial reaches the peer echo server and round-trips bytes',
      () async {
        final conn = await tsnet.tcp
            .dial(peer.ipv4, 7000, timeout: const Duration(seconds: 30))
            .timeout(const Duration(seconds: 30));

        try {
          final payload = utf8.encode(
            'tcp-echo-${DateTime.now().microsecondsSinceEpoch}',
          );
          await conn.output.write(payload);
          await conn.output.close();

          final received = BytesBuilder();
          await for (final chunk in conn.input.timeout(
            const Duration(seconds: 15),
            onTimeout: (sink) => sink.close(),
          )) {
            received.add(chunk);
            if (received.length >= payload.length) break;
          }
          expect(received.takeBytes(), payload);
        } finally {
          await conn.close();
        }
      },
    );

    test('tcp.dial round-trips a 1 MiB payload end-to-end', () async {
      final conn = await tsnet.tcp
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
          await conn.output.write(payload);
          await conn.output.close(); // half-close signal — peer stops reading
        }();

        final received = BytesBuilder();
        await for (final chunk in conn.input.timeout(
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
        await conn.close();
      }
    });

    test('udp.bind sends and receives datagrams end-to-end', () async {
      final binding = await tsnet.udp
          .bind(port: 0)
          .timeout(const Duration(seconds: 30));
      final iterator = StreamIterator(binding.datagrams);
      addTearDown(iterator.cancel);
      addTearDown(binding.close);

      final payload = utf8.encode(
        'udp-echo-${DateTime.now().microsecondsSinceEpoch}',
      );
      final firstDatagram = iterator.moveNext().timeout(
        const Duration(seconds: 15),
      );
      await Future<void>.delayed(Duration.zero);
      await binding.send(
        payload,
        to: TailscaleEndpoint(address: peer.ipv4, port: 7001),
      );

      expect(await firstDatagram, isTrue);
      expect(iterator.current.remote.address, peer.ipv4);
      expect(iterator.current.remote.port, 7001);
      expect(iterator.current.payload, payload);
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

    test('onNodeChanges emits while nodes are online', () async {
      for (var i = 0; i < 30; i++) {
        final identity = await tsnet.whois(peer.ipv4);
        if (identity != null) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      final first = await tsnet.onNodeChanges.first.timeout(
        const Duration(seconds: 2),
      );
      expect(first, isNotEmpty);
      expect(first.any((p) => p.ipv4 == peer.ipv4), isTrue);
    });

    test('diag.ping reaches the peer', () async {
      final result = await tsnet.diag
          .ping(peer.ipv4, timeout: const Duration(seconds: 10))
          .timeout(const Duration(seconds: 15));
      expect(result.latency, greaterThan(Duration.zero));
      expect(result.path, isNot(PingPath.unknown));
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

    test(
      'tls.bind fails clearly when Headscale cannot provision certs',
      () async {
        await expectLater(
          tsnet.tls.bind(port: 443),
          throwsA(isA<TailscaleTlsException>()),
        );
      },
    );
  });

  group('peer reconnects with persisted credentials', () {
    late String persistStateDir;
    String? firstIpv4;

    setUpAll(() {
      persistStateDir = Directory.systemTemp
          .createTempSync('tailscale_e2e_persist_')
          .path;
    });

    tearDownAll(() {
      try {
        Directory(persistStateDir).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('first launch registers and persists credentials', () async {
      final peer = await PeerProcess.spawn(
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
      final peer = await PeerProcess.spawn(
        stateDir: persistStateDir,
        controlUrl: controlUrl,
        // Deliberately no authKey — must come up from persisted state.
        hostname: 'dune-e2e-persist',
      );
      addTearDown(peer.shutdown);
      expect(
        peer.ipv4,
        firstIpv4,
        reason: 'reconnect should keep the same tailnet IPv4',
      );
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
    Future<void> reconnect() =>
        tsnet.up(hostname: hostname, controlUrl: Uri.parse(controlUrl));

    setUp(() async {
      // Route each normalization transition through [recordUntil] so its
      // events are captured by setUp's subscription instead of leaking
      // into the test's subscription.
      switch ((await tsnet.status()).state) {
        case NodeState.noState:
          // Logout wiped creds. Re-establish and shut down.
          await recordUntil(tsnet, NodeState.running, bringUp);
          await recordUntil(tsnet, NodeState.stopped, tsnet.down);
        case NodeState.running:
          await recordUntil(tsnet, NodeState.stopped, tsnet.down);
        case NodeState.stopped:
          break;
        case final unexpected:
          fail('unexpected entry state for lifecycle setUp: $unexpected');
      }
    });

    test('up with auth key emits Starting → Running', () async {
      final sequence = await recordUntil(tsnet, NodeState.running, bringUp);

      expect(
        sequence,
        containsAllInOrder([NodeState.starting, NodeState.running]),
        reason:
            'UI subscribers depend on Starting to show a "connecting" '
            'state before Running',
      );
      expect((await tsnet.status()).state, NodeState.running);
    });

    test('down from running emits [Stopped]', () async {
      await recordUntil(tsnet, NodeState.running, bringUp);

      final sequence = await recordUntil(tsnet, NodeState.stopped, tsnet.down);

      expect(
        sequence,
        equals([NodeState.stopped]),
        reason:
            'down() should emit exactly the synthetic Stopped from '
            'Stop(); extra events mean the IPN watcher is leaking '
            'transitions across the teardown boundary',
      );
      expect((await tsnet.status()).state, NodeState.stopped);
    });

    test('up without auth key reconnects via persisted credentials', () async {
      final sequence = await recordUntil(tsnet, NodeState.running, reconnect);

      expect(
        sequence,
        containsAllInOrder([NodeState.starting, NodeState.running]),
        reason:
            'reconnect must still transition through Starting — same '
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
        reason:
            'Stop() only publishes when wasRunning (srv != nil); a '
            'no-op down() must not reach subscribers',
      );
    });

    test(
      'onStateChange delivers to multiple subscribers (broadcast)',
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
      },
    );

    test(
      'logout from running emits [Stopped, NoState] and clears creds',
      () async {
        await recordUntil(tsnet, NodeState.running, bringUp);

        final sequence = await recordUntil(
          tsnet,
          NodeState.noState,
          tsnet.logout,
        );

        expect(
          sequence,
          equals([NodeState.stopped, NodeState.noState]),
          reason:
              'logout from running must emit Stopped then NoState — '
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
      },
    );

    test('logout from stopped emits [NoState] (no phantom Stopped)', () async {
      final sequence = await recordUntil(
        tsnet,
        NodeState.noState,
        tsnet.logout,
      );

      expect(
        sequence,
        equals([NodeState.noState]),
        reason:
            "logout from stopped must not emit Stopped — Stop()'s "
            'wasRunning guard skips the publish when srv is nil',
      );
      expect((await tsnet.status()).state, NodeState.noState);
    });

    // Consecutive-duplicate scenarios — the stream filters these in
    // [Tailscale.onStateChange]. Each test attaches a
    // single subscription across two transitions so the filter's internal
    // "previous" state carries over; a single subscription on a fresh
    // state-change stream would only see the second event and wouldn't prove
    // the filter fired.

    test('up() while already running does not re-emit Running', () async {
      var runningCount = 0;
      final sub = tsnet.onStateChange.listen((s) {
        if (s == NodeState.running) runningCount++;
      });

      // First up — real transition, emits Running.
      await recordUntil(tsnet, NodeState.running, bringUp);
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
        reason:
            'a no-op up() must not surface a second Running to the '
            'stream — onStateChange filters the watcher reattach duplicate',
      );
    });

    test('logout() twice does not re-emit NoState', () async {
      // Bring up *before* subscribing so the IPN watcher's initial
      // NoState emit (during engine startup) doesn't show up in our
      // count — we want to isolate the logout emits.
      await recordUntil(tsnet, NodeState.running, bringUp);

      var noStateCount = 0;
      final sub = tsnet.onStateChange.listen((s) {
        if (s == NodeState.noState) noStateCount++;
      });

      // First logout — emits Stopped then NoState. Both pass (different
      // from each other; the previous-state filter starts at null for this
      // fresh stream).
      await recordUntil(tsnet, NodeState.noState, tsnet.logout);

      // Second logout — srv already nil (wasRunning guard skips Stop's
      // Stopped publish), state dir already gone, but Logout still
      // calls publishState("NoState"). onStateChange filters the duplicate
      // because _previous is NoState from the first logout.
      await tsnet.logout();
      await Future<void>.delayed(const Duration(seconds: 1));
      await sub.cancel();

      expect(
        noStateCount,
        1,
        reason:
            'a redundant logout() must not surface a second NoState — '
            'onStateChange filters publishState("NoState") when it matches '
            'the most recently emitted state',
      );
    });
  });
}
