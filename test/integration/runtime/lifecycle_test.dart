/// Coverage for the top-level lifecycle namespace on [Tailscale]:
/// init, up/down/logout, status/nodes, the state/error streams, and
/// parsing of the [TailscaleStatus] / [TailscaleNode] value types the
/// lifecycle returns.
///
/// The FFI-backed integration tests (up/down against the real Go
/// runtime) gate on `mac-os || linux` because the build hook only
/// produces the native library on those hosts.
@TestOn('mac-os || linux')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

import '../support/process_state_root.dart';

void main() {
  // ─── Pure-Dart value-type parsing ─────────────────────────────────
  // Doesn't touch FFI; the @TestOn at the top is for the integration
  // groups further down.
  group('TailscaleStatus.fromJson', () {
    test('parses local-node fields from status JSON', () {
      final json = {
        'BackendState': 'Running',
        'AuthURL': '',
        'Self': {
          'ID': 'nSelf1234',
          'TailscaleIPs': ['100.64.0.1', 'fd7a:115c:a1e0::1'],
          'HostName': 'my-node',
        },
        'Peer': {
          'key1': {
            'PublicKey': 'abc123',
            'HostName': 'peer-1',
            'DNSName': 'peer-1.tailnet.ts.net',
            'OS': 'linux',
            'TailscaleIPs': ['100.64.0.2'],
            'Online': true,
            'Active': true,
            'RxBytes': 1024,
            'TxBytes': 2048,
            'Relay': 'nyc',
          },
        },
        'Health': <String>[],
        'CurrentTailnet': {'MagicDNSSuffix': 'tailnet.ts.net'},
      };

      final status = TailscaleStatus.fromJson(json);

      expect(status.state, NodeState.running);
      expect(status.isRunning, isTrue);
      expect(status.needsLogin, isFalse);
      expect(status.isHealthy, isTrue);
      expect(status.stableNodeId, 'nSelf1234');
      expect(status.tailscaleIPs, ['100.64.0.1', 'fd7a:115c:a1e0::1']);
      expect(status.ipv4, '100.64.0.1');
      expect(status.magicDNSSuffix, 'tailnet.ts.net');
    });

    test('handles empty/minimal JSON', () {
      final status = TailscaleStatus.fromJson({});
      expect(status.state, NodeState.noState);
      expect(status.isRunning, isFalse);
      expect(status.stableNodeId, isNull);
      expect(status.tailscaleIPs, isEmpty);
      expect(status.health, isEmpty);
      expect(status.isHealthy, isTrue);
    });

    test('NeedsLogin state populates authUrl', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'NeedsLogin',
        'AuthURL': 'https://login.tailscale.com/a/abc123',
      });
      expect(status.state, NodeState.needsLogin);
      expect(status.needsLogin, isTrue);
      expect(status.authUrl?.host, 'login.tailscale.com');
    });

    test('empty auth URL parses to null', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'NeedsLogin',
        'AuthURL': '',
      });
      expect(status.authUrl, isNull);
    });

    test('ignores node inventory', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Self': {
          'TailscaleIPs': ['100.64.0.1'],
        },
        'Peer': {
          'key1': {'PublicKey': 'abc123', 'HostName': 'peer-1'},
        },
      });
      expect(status.isRunning, isTrue);
      expect(status.ipv4, '100.64.0.1');
    });

    test('surfaces health warnings', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Health': ['no connectivity to DERP servers'],
      });
      expect(status.isHealthy, isFalse);
      expect(status.health, hasLength(1));
    });

    test('stopped constant', () {
      expect(TailscaleStatus.stopped.state, NodeState.stopped);
      expect(TailscaleStatus.stopped.isRunning, isFalse);
    });

    test('TailscaleStatus ==', () {
      const a = TailscaleStatus(
        state: NodeState.running,
        stableNodeId: 'n1',
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      const b = TailscaleStatus(
        state: NodeState.running,
        stableNodeId: 'n1',
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      const c = TailscaleStatus(
        state: NodeState.stopped,
        stableNodeId: 'n2',
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });

  group('NodeState.parse', () {
    test('all known values parse correctly', () {
      for (final entry in {
        'NoState': NodeState.noState,
        'NeedsLogin': NodeState.needsLogin,
        'NeedsMachineAuth': NodeState.needsMachineAuth,
        'Starting': NodeState.starting,
        'Running': NodeState.running,
        'Stopped': NodeState.stopped,
      }.entries) {
        final status = TailscaleStatus.fromJson({'BackendState': entry.key});
        expect(status.state, entry.value, reason: entry.key);
      }
    });

    test('unknown value remains distinguishable from noState', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'SomeFutureState',
      });
      expect(status.state, NodeState.unknown);
      expect(TailscaleStatus.fromJson(const {}).state, NodeState.noState);
    });
  });

  group('TailscaleNode.fromJson', () {
    test('parses all documented fields', () {
      final node = TailscaleNode.fromJson({
        'PublicKey': 'abc123',
        'ID': 'nAbCd1234',
        'HostName': 'peer-1',
        'DNSName': 'peer-1.tailnet.ts.net',
        'OS': 'linux',
        'TailscaleIPs': ['100.64.0.2', 'fd7a:115c:a1e0::2'],
        'Online': true,
        'Active': true,
        'RxBytes': 1024,
        'TxBytes': 2048,
        'ExitNode': true,
        'ExitNodeOption': true,
        'LastSeen': '2026-04-08T12:00:00Z',
        'Relay': 'nyc',
        'CurAddr': '1.2.3.4:41641',
      });

      expect(node.publicKey, 'abc123');
      expect(node.stableNodeId, 'nAbCd1234');
      expect(node.hostName, 'peer-1');
      expect(node.os, 'linux');
      expect(node.online, isTrue);
      expect(node.ipv4, '100.64.0.2');
      expect(node.rxBytes, 1024);
      expect(node.txBytes, 2048);
      expect(node.exitNode, isTrue);
      expect(node.exitNodeOption, isTrue);
      expect(node.lastSeen, isNotNull);
      expect(node.relay, 'nyc');
      expect(node.curAddr, '1.2.3.4:41641');
    });

    test('stableNodeId falls back to empty string when absent', () {
      final node = TailscaleNode.fromJson({'PublicKey': 'abc123'});
      expect(node.stableNodeId, '');
    });

    test('listFromJson parses multiple nodes', () {
      final nodes = TailscaleNode.listFromJson([
        {
          'PublicKey': 'abc',
          'ID': 'n1',
          'HostName': 'peer-1',
          'DNSName': 'peer-1.tailnet.ts.net.',
          'OS': 'linux',
          'TailscaleIPs': ['100.64.0.2'],
          'Online': true,
          'Active': true,
          'RxBytes': 0,
          'TxBytes': 0,
        },
        {
          'PublicKey': 'def',
          'ID': 'n2',
          'HostName': 'peer-2',
          'DNSName': 'peer-2.tailnet.ts.net.',
          'OS': 'macOS',
          'TailscaleIPs': ['100.64.0.3'],
          'Online': false,
          'Active': false,
          'RxBytes': 0,
          'TxBytes': 0,
        },
      ]);

      expect(nodes, hasLength(2));
      expect(nodes.first.hostName, 'peer-1');
      expect(nodes.first.stableNodeId, 'n1');
      expect(nodes.last.online, isFalse);
    });

    test('TailscaleNode == includes stableNodeId', () {
      final base = {
        'PublicKey': 'abc',
        'ID': 'n1',
        'HostName': 'h',
        'DNSName': 'h.tailnet.ts.net.',
        'OS': 'linux',
        'TailscaleIPs': ['100.64.0.2'],
        'Online': true,
        'Active': true,
        'RxBytes': 0,
        'TxBytes': 0,
      };
      final a = TailscaleNode.fromJson({...base});
      final b = TailscaleNode.fromJson({...base});
      final c = TailscaleNode.fromJson({...base, 'ID': 'n2'});
      final d = TailscaleNode.fromJson({...base, 'ExitNode': true});
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });
  });

  group('TailscaleLogLevel', () {
    test('values remain stable', () {
      expect(TailscaleLogLevel.values, [
        TailscaleLogLevel.silent,
        TailscaleLogLevel.error,
        TailscaleLogLevel.info,
      ]);
    });
  });

  // ─── FFI-backed lifecycle integration ────────────────────────────
  // Runs the user-facing API against the real embedded Go runtime.
  // Tests share one configured state-base dir so they exercise the
  // expected sequences (up → down → up → logout).
  late Directory configuredStateBaseDir;

  setUpAll(() {
    configuredStateBaseDir = processIntegrationStateRoot();
    clearProcessIntegrationState(configuredStateBaseDir);
    Tailscale.init(
      stateDir: configuredStateBaseDir.path,
      appId: processIntegrationAppId,
    );
  });

  tearDownAll(() async {
    await forgetProcessIntegrationState(configuredStateBaseDir);
  });

  group('init validation', () {
    test('rejects empty stateDir', () {
      expect(
        () => Tailscale.init(stateDir: '', appId: processIntegrationAppId),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(
        () => Tailscale.init(stateDir: '   ', appId: processIntegrationAppId),
        throwsA(isA<TailscaleUsageException>()),
      );
    });

    test('rejects invalid appId before preparing a state root', () {
      final parent = Directory.systemTemp.createTempSync(
        'tailscale_invalid_app_id_',
      );
      addTearDown(() {
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });
      final proposedRoot = Directory(p.join(parent.path, 'must-not-exist'));

      expect(
        () => Tailscale.init(
          stateDir: proposedRoot.path,
          appId: 'invalid/app-id',
        ),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(proposedRoot.existsSync(), isFalse);
    });

    test('up rejects non-positive timeout', () async {
      await expectLater(
        Tailscale.instance.up(
          authKey: 'tskey-fake-key',
          timeout: Duration.zero,
        ),
        throwsA(isA<TailscaleUsageException>()),
      );
    });

    test('repeated init is idempotent only for the same full identity', () {
      Tailscale.init(
        stateDir: configuredStateBaseDir.path,
        appId: processIntegrationAppId,
      );

      final alias = Link('${configuredStateBaseDir.path}-alias');
      if (alias.existsSync()) alias.deleteSync();
      alias.createSync(configuredStateBaseDir.path);
      addTearDown(() {
        if (alias.existsSync()) alias.deleteSync();
      });
      Tailscale.init(stateDir: alias.path, appId: processIntegrationAppId);

      expect(
        () => Tailscale.init(
          stateDir: configuredStateBaseDir.path,
          appId: 'dev.tailscale.dart.test.otherLifecycle',
        ),
        throwsA(isA<TailscaleConfigurationException>()),
      );
      expect(
        () => Tailscale.init(
          stateDir: configuredStateBaseDir.path,
          appId: 'Dev.Tailscale.Dart.Test.Lifecycle',
        ),
        throwsA(isA<TailscaleConfigurationException>()),
      );

      expect(
        () => Tailscale.init(
          stateDir: configuredStateBaseDir.path,
          appId: processIntegrationAppId,
          logLevel: TailscaleLogLevel.error,
        ),
        throwsA(isA<TailscaleConfigurationException>()),
      );
      final otherRoot = Directory.systemTemp.createTempSync(
        'tailscale_other_root_',
      );
      addTearDown(() {
        if (otherRoot.existsSync()) otherRoot.deleteSync(recursive: true);
      });
      expect(
        () => Tailscale.init(
          stateDir: otherRoot.path,
          appId: processIntegrationAppId,
        ),
        throwsA(isA<TailscaleConfigurationException>()),
      );

      Tailscale.init(
        stateDir: configuredStateBaseDir.path,
        appId: processIntegrationAppId,
      );
    });

    test('Keybay namespace identity is frozen across Dart isolates', () async {
      final stateDir = configuredStateBaseDir.path;
      final outcome = await Isolate.run(() {
        try {
          Tailscale.init(
            stateDir: stateDir,
            appId: 'dev.tailscale.dart.test.otherIsolate',
          );
          return 'accepted';
        } on TailscaleConfigurationException {
          return 'configurationMismatch';
        }
      });

      expect(outcome, 'configurationMismatch');
    });
  });

  group('streams', () {
    test('onStateChange is a broadcast stream', () {
      expect(Tailscale.instance.onStateChange.isBroadcast, isTrue);
    });

    test('onError is a broadcast stream', () {
      expect(Tailscale.instance.onError.isBroadcast, isTrue);
    });

    test('onNodeChanges is a broadcast stream', () {
      expect(Tailscale.instance.onNodeChanges.isBroadcast, isTrue);
    });

    test('onNodeChanges emits current snapshot on listen', () async {
      await expectLater(
        Tailscale.instance.onNodeChanges.first.timeout(
          const Duration(seconds: 1),
        ),
        completion(isEmpty),
      );
    });
  });

  group('status() before up()', () {
    test('returns noState when no persisted state', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }

      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.noState);
    });

    test('nodes() returns empty list before up()', () async {
      final nodes = await Tailscale.instance.nodes();
      expect(nodes, isEmpty);
    });

    test('down() is a no-op before up()', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('logout() does not throw before up()', () async {
      await expectLater(Tailscale.instance.logout(), completes);
    });
  });

  group('up() without auth key', () {
    test('defers fresh enrollment truth to upstream', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }

      final status = await Tailscale.instance.up(
        hostname: 'no-auth-test',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      expect(status.state, NodeState.needsLogin);
      await Tailscale.instance.down();
    });
  });

  group('up/down lifecycle', () {
    test('up() starts the node and delivers state events', () async {
      final firstEvent = Tailscale.instance.onStateChange.first;

      await Tailscale.instance.up(
        hostname: 'lifecycle-test',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));

      final state = await firstEvent.timeout(const Duration(seconds: 5));
      expect(state, isA<NodeState>());
    });

    test('down() succeeds', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('status() after down() returns stopped (persisted state)', () async {
      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.stopped);
      expect(status.tailscaleIPs, isEmpty);
    });

    test('nodes() after down() returns empty', () async {
      final nodes = await Tailscale.instance.nodes();
      expect(nodes, isEmpty);
    });

    test('down() twice is a no-op', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('up() restarts after down()', () async {
      await Tailscale.instance.up(
        hostname: 'lifecycle-restart',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));

      await Tailscale.instance.down();
    });

    test(
      'same-config up ignores a new auth key and preserves generation',
      () async {
        addTearDown(() async {
          try {
            await Tailscale.instance.down();
          } catch (_) {}
        });

        await Tailscale.instance.up(
          hostname: 'double-up',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        );
        final before = await Tailscale.instance.diag.nodeState();

        await Tailscale.instance.up(
          hostname: 'double-up',
          authKey: 'tskey-a-different-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        );

        final status = await Tailscale.instance.status();
        expect(status.state, isNot(NodeState.noState));
        final after = await Tailscale.instance.diag.nodeState();
        expect(after.epoch, before.epoch);
      },
    );

    test('active config mismatch is typed and does not tear down', () async {
      addTearDown(() async {
        try {
          await Tailscale.instance.down();
        } catch (_) {}
      });
      await Tailscale.instance.up(
        hostname: 'mismatch-base',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      final before = await Tailscale.instance.diag.nodeState();

      await expectLater(
        Tailscale.instance.up(
          hostname: 'different-hostname',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.configurationMismatch,
          ),
        ),
      );

      final after = await Tailscale.instance.diag.nodeState();
      expect(after.epoch, before.epoch);
      expect(
        (await Tailscale.instance.status()).state,
        isNot(NodeState.noState),
      );

      await Tailscale.instance.down();
    });

    test('concurrent up returns lifecycleBusy', () async {
      final first = Tailscale.instance.up(
        hostname: 'busy-start',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      await expectLater(
        Tailscale.instance.up(
          hostname: 'busy-start',
          authKey: 'tskey-other-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.lifecycleBusy,
          ),
        ),
      );

      await first;
      await Tailscale.instance.down();
    });

    test('down called during up is ordered after start', () async {
      final starting = Tailscale.instance.up(
        hostname: 'ordered-up-down',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      final stopping = Tailscale.instance.down();

      await starting;
      await stopping;

      expect((await Tailscale.instance.status()).state, NodeState.stopped);
      final census = await Tailscale.instance.diag.nodeState();
      expect(census.servePublications, 0);
      expect(census.httpBindings, 0);
      expect(census.tcpListeners, 0);
      expect(census.udpBridges, 0);
      expect(census.transportCached, isFalse);
    });

    test('up timeout quarantines its token before a later start', () async {
      await expectLater(
        Tailscale.instance.up(
          hostname: 'timeout-quarantine',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
          timeout: const Duration(microseconds: 1),
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupTimeout,
          ),
        ),
      );

      final restarted = await Tailscale.instance.up(
        hostname: 'timeout-quarantine',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      expect(
        restarted.state,
        anyOf(NodeState.needsLogin, NodeState.needsMachineAuth),
      );
      await Tailscale.instance.down();
    });

    test('timed-out idempotent up preserves the active runtime', () async {
      await Tailscale.instance.up(
        hostname: 'idempotent-timeout',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      final clientBefore = Tailscale.instance.http.client;

      await expectLater(
        Tailscale.instance.up(
          hostname: 'idempotent-timeout',
          authKey: 'tskey-different-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
          timeout: const Duration(microseconds: 1),
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupTimeout,
          ),
        ),
      );

      expect(
        (await Tailscale.instance.status()).state,
        isNot(NodeState.noState),
      );
      expect(Tailscale.instance.http.client, same(clientBefore));
      await Tailscale.instance.down();
    });

    test('worker exit fails the exact up before replacement starts', () async {
      await Tailscale.instance.debugTerminateWorkerForTesting(
        at: DebugTerminatePoint.afterNextStart,
      );
      final incident = Tailscale.instance.onError.firstWhere(
        (error) => error.code == TailscaleRuntimeErrorCode.worker,
      );
      final stopped = Tailscale.instance.onStateChange.firstWhere(
        (state) => state == NodeState.stopped,
      );

      await expectLater(
        Tailscale.instance.up(
          hostname: 'worker-exit-during-up',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        ),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.workerTerminated,
          ),
        ),
      );
      await incident.timeout(const Duration(seconds: 10));
      await stopped.timeout(const Duration(seconds: 10));

      final restarted = await Tailscale.instance.up(
        hostname: 'worker-exit-during-up',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      expect(restarted.state, isNot(NodeState.noState));
      await Tailscale.instance.down();
    });

    test(
      'unexpected worker exit quarantines and permits replacement',
      () async {
        await Tailscale.instance.up(
          hostname: 'worker-failsafe',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        );

        final sequence = <String>[];
        final incidents = <TailscaleRuntimeError>[];
        final errorSub = Tailscale.instance.onError.listen((error) {
          incidents.add(error);
          sequence.add('error:${error.code.name}');
        });
        final stateSub = Tailscale.instance.onStateChange.listen((state) {
          sequence.add('state:${state.name}');
        });
        addTearDown(errorSub.cancel);
        addTearDown(stateSub.cancel);

        final incident = Tailscale.instance.onError.firstWhere(
          (error) => error.code == TailscaleRuntimeErrorCode.worker,
        );
        final stopped = Tailscale.instance.onStateChange.firstWhere(
          (state) => state == NodeState.stopped,
        );

        await Tailscale.instance.debugTerminateWorkerForTesting();
        await incident.timeout(const Duration(seconds: 10));
        await stopped.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          incidents
              .where((error) => error.code == TailscaleRuntimeErrorCode.worker)
              .length,
          1,
        );
        expect(
          sequence.indexOf('error:worker'),
          lessThan(sequence.indexOf('state:stopped')),
        );
        expect((await Tailscale.instance.status()).state, NodeState.stopped);

        final census = await Tailscale.instance.diag.nodeState();
        expect(census.servePublications, 0);
        expect(census.httpBindings, 0);
        expect(census.tcpListeners, 0);
        expect(census.udpBridges, 0);
        expect(census.transportCached, isFalse);
      },
    );

    test('worker exit during down is rescued by the initiating call', () async {
      await Tailscale.instance.up(
        hostname: 'worker-expected-exit',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final incidents = <TailscaleRuntimeError>[];
      final errorSub = Tailscale.instance.onError.listen(incidents.add);
      addTearDown(errorSub.cancel);

      await Tailscale.instance.debugTerminateWorkerForTesting(
        at: DebugTerminatePoint.nextShutdown,
      );
      await expectLater(Tailscale.instance.down(), completes);
      final status = await Tailscale.instance.status().timeout(
        const Duration(seconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(status.state, NodeState.stopped);
      expect(
        incidents.where(
          (error) => error.code == TailscaleRuntimeErrorCode.worker,
        ),
        isEmpty,
      );

      await Tailscale.instance.up(
        hostname: 'worker-expected-exit',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      await Tailscale.instance.down();
    });

    test('lost down response is recovered from the native receipt', () async {
      await Tailscale.instance.up(
        hostname: 'lost-down-receipt',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final states = <NodeState>[];
      final stateSub = Tailscale.instance.onStateChange.listen(states.add);
      addTearDown(stateSub.cancel);

      await Tailscale.instance.debugTerminateWorkerForTesting(
        at: DebugTerminatePoint.afterNextLifecycleNativeResult,
      );
      await expectLater(Tailscale.instance.down(), completes);
      expect((await Tailscale.instance.status()).state, NodeState.stopped);
      expect(states.where((state) => state == NodeState.stopped), hasLength(1));
    });
  });

  group('logout', () {
    test(
      'worker exit after logout dispatch preserves truthful result',
      () async {
        await Tailscale.instance.up(
          hostname: 'logout-worker-exit',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        );
        final incidents = <TailscaleRuntimeError>[];
        final states = <NodeState>[];
        final errorSub = Tailscale.instance.onError.listen(incidents.add);
        final stateSub = Tailscale.instance.onStateChange.listen(states.add);
        addTearDown(errorSub.cancel);
        addTearDown(stateSub.cancel);

        await Tailscale.instance.debugTerminateWorkerForTesting(
          at: DebugTerminatePoint.afterNextLogoutDispatch,
        );
        TailscaleLogoutException? logoutError;
        try {
          await Tailscale.instance.logout();
        } on TailscaleLogoutException catch (error) {
          logoutError = error;
        }
        if (logoutError != null) {
          expect(logoutError.code, TailscaleErrorCode.logoutIndeterminate);
        }
        final status = await Tailscale.instance.status().timeout(
          const Duration(seconds: 10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          status.state,
          logoutError == null ? NodeState.noState : NodeState.stopped,
          reason: 'idle status authenticates the retained encrypted Store',
        );
        expect(
          incidents.where(
            (error) => error.code == TailscaleRuntimeErrorCode.worker,
          ),
          isEmpty,
        );
        expect(states.where((state) => state == NodeState.stopped).length, 1);
        expect(states, isNotEmpty);
        expect(
          states.last,
          logoutError == null ? NodeState.noState : NodeState.stopped,
          reason: 'the terminal stream agrees with the authenticated result',
        );
      },
    );

    test(
      'lost idle logout response releases its prepared state lease',
      () async {
        await Tailscale.instance.up(
          hostname: 'idle-logout-response-loss',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        );
        await Tailscale.instance.down();
        await Tailscale.instance.debugTerminateWorkerForTesting(
          at: DebugTerminatePoint.afterNextLifecycleNativeResult,
        );

        try {
          await Tailscale.instance.logout();
        } on TailscaleLogoutException catch (error) {
          expect(error.code, TailscaleErrorCode.logoutIndeterminate);
        }

        final status = await Tailscale.instance.status().timeout(
          const Duration(seconds: 10),
        );
        expect(status.state, anyOf(NodeState.stopped, NodeState.noState));
      },
    );

    test(
      'absent logout preserves root siblings without creating owned state',
      () async {
        await Tailscale.instance.forgetLocalIdentity();
        final ownedStateDir = Directory(
          p.join(configuredStateBaseDir.path, 'tailscale'),
        );
        expect(ownedStateDir.existsSync(), isFalse);

        final preservedFile = File(
          p.join(configuredStateBaseDir.path, 'keep.txt'),
        )..writeAsStringSync('keep');

        await Tailscale.instance.logout();

        expect(configuredStateBaseDir.existsSync(), isTrue);
        expect(preservedFile.existsSync(), isTrue);
        expect(ownedStateDir.existsSync(), isFalse);
      },
    );

    test('repeated absent logout remains a no-op', () async {
      await Tailscale.instance.forgetLocalIdentity();
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      expect(ownedStateDir.existsSync(), isFalse);

      final states = <NodeState>[];
      final stateSub = Tailscale.instance.onStateChange.listen(states.add);
      addTearDown(stateSub.cancel);

      await expectLater(Tailscale.instance.logout(), completes);
      expect((await Tailscale.instance.status()).state, NodeState.noState);
      expect(ownedStateDir.existsSync(), isFalse);
      expect(states.where((state) => state == NodeState.noState), hasLength(1));
    });

    test('logout() twice does not throw', () async {
      await expectLater(Tailscale.instance.logout(), completes);
    });
  });

  group('forgetLocalIdentity', () {
    test('failed custody deletion leaves a resumable reset marker', () async {
      await Tailscale.instance.up(
        hostname: 'forget-retry',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );
      await Tailscale.instance.down();
      failNextProcessIntegrationCustodyDelete();

      await expectLater(
        Tailscale.instance.forgetLocalIdentity(),
        throwsA(
          isA<TailscaleForgetLocalIdentityException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.localResetIncomplete,
          ),
        ),
      );
      await expectLater(
        Tailscale.instance.status(),
        throwsA(
          isA<TailscaleStatusException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.localResetIncomplete,
          ),
        ),
      );

      await Tailscale.instance.forgetLocalIdentity();
      expect((await Tailscale.instance.status()).state, NodeState.noState);
      expect(
        Directory(
          p.join(configuredStateBaseDir.path, 'tailscale'),
        ).existsSync(),
        isFalse,
      );
    });

    test('active reset stops and removes the exact local identity', () async {
      await Tailscale.instance.up(
        hostname: 'forget-active',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      await Tailscale.instance.forgetLocalIdentity();

      expect((await Tailscale.instance.status()).state, NodeState.noState);
    });
  });
}
