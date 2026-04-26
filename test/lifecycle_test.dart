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

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

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

    test('unknown value falls back to noState', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'SomeFutureState',
      });
      expect(status.state, NodeState.noState);
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
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
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
    native.duneSetLogLevel(0);
    configuredStateBaseDir = Directory.systemTemp.createTempSync(
      'tailscale_lifecycle_',
    );
    Tailscale.init(stateDir: configuredStateBaseDir.path);
  });

  tearDownAll(() {
    if (configuredStateBaseDir.existsSync()) {
      configuredStateBaseDir.deleteSync(recursive: true);
    }
  });

  group('init validation', () {
    test('rejects empty stateDir', () {
      expect(
        () => Tailscale.init(stateDir: ''),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(
        () => Tailscale.init(stateDir: '   '),
        throwsA(isA<TailscaleUsageException>()),
      );
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
    test('throws TailscaleUpException when no persisted state', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }

      await expectLater(
        Tailscale.instance.up(
          hostname: 'no-auth-test',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        ),
        throwsA(isA<TailscaleUpException>()),
      );
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

    test('up() twice without down() replaces the node', () async {
      addTearDown(() async {
        try {
          await Tailscale.instance.down();
        } catch (_) {}
        native.duneStop();
      });

      await Tailscale.instance.up(
        hostname: 'double-up-1',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      await Tailscale.instance.up(
        hostname: 'double-up-2',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));
    });
  });

  group('logout', () {
    test('removes only the owned state subdirectory', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }
      ownedStateDir.createSync(recursive: true);

      final preservedFile = File(
        p.join(configuredStateBaseDir.path, 'keep.txt'),
      )..writeAsStringSync('keep');
      File(
        p.join(ownedStateDir.path, 'state.db'),
      ).writeAsStringSync('placeholder');

      await Tailscale.instance.logout();

      expect(configuredStateBaseDir.existsSync(), isTrue);
      expect(preservedFile.existsSync(), isTrue);
      expect(ownedStateDir.existsSync(), isFalse);
    });

    test('logout() twice does not throw', () async {
      await expectLater(Tailscale.instance.logout(), completes);
    });
  });
}
