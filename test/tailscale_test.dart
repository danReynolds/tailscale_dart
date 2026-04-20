import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('TailscaleStatus', () {
    test('parses local-node fields from status JSON', () {
      final json = {
        'BackendState': 'Running',
        'AuthURL': '',
        'Self': {
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
          'key2': {
            'PublicKey': 'def456',
            'HostName': 'peer-2',
            'DNSName': 'peer-2.tailnet.ts.net',
            'OS': 'macOS',
            'TailscaleIPs': ['100.64.0.3'],
            'Online': false,
            'Active': false,
            'RxBytes': 0,
            'TxBytes': 0,
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
      expect(status.tailscaleIPs, ['100.64.0.1', 'fd7a:115c:a1e0::1']);
      expect(status.ipv4, '100.64.0.1');
      expect(status.magicDNSSuffix, 'tailnet.ts.net');
    });

    test('parses PeerStatus', () {
      final json = {
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
      };

      final peer = PeerStatus.fromJson(json);

      expect(peer.publicKey, 'abc123');
      expect(peer.stableNodeId, 'nAbCd1234');
      expect(peer.hostName, 'peer-1');
      expect(peer.os, 'linux');
      expect(peer.online, isTrue);
      expect(peer.ipv4, '100.64.0.2');
      expect(peer.rxBytes, 1024);
      expect(peer.txBytes, 2048);
      expect(peer.lastSeen, isNotNull);
      expect(peer.relay, 'nyc');
      expect(peer.curAddr, '1.2.3.4:41641');
    });

    test('PeerStatus stableNodeId falls back to empty string when absent', () {
      final peer = PeerStatus.fromJson({'PublicKey': 'abc123'});
      expect(peer.stableNodeId, '');
    });

    test('parses PeerStatus list snapshots', () {
      final peers = PeerStatus.listFromJson([
        {
          'PublicKey': 'abc123',
          'ID': 'n1',
          'HostName': 'peer-1',
          'DNSName': 'peer-1.tailnet.ts.net.',
          'OS': 'linux',
          'TailscaleIPs': ['100.64.0.2'],
          'Online': true,
          'Active': true,
          'RxBytes': 1024,
          'TxBytes': 2048,
        },
        {
          'PublicKey': 'def456',
          'ID': 'n2',
          'HostName': 'peer-2',
          'DNSName': 'peer-2.tailnet.ts.net.',
          'OS': 'macOS',
          'TailscaleIPs': ['100.64.0.3'],
          'Online': false,
          'Active': false,
          'RxBytes': 1,
          'TxBytes': 2,
        },
      ]);

      expect(peers, hasLength(2));
      expect(peers.first.hostName, 'peer-1');
      expect(peers.first.stableNodeId, 'n1');
      expect(peers.last.online, isFalse);
    });

    test('handles empty/minimal JSON', () {
      final status = TailscaleStatus.fromJson({});

      expect(status.state, NodeState.noState);
      expect(status.isRunning, isFalse);
      expect(status.tailscaleIPs, isEmpty);
      expect(status.health, isEmpty);
      expect(status.isHealthy, isTrue);
    });

    test('NeedsLogin state', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'NeedsLogin',
        'AuthURL': 'https://login.tailscale.com/a/abc123',
      });

      expect(status.state, NodeState.needsLogin);
      expect(status.needsLogin, isTrue);
      expect(status.isRunning, isFalse);
      expect(status.authUrl, isA<Uri>());
      expect(status.authUrl?.host, 'login.tailscale.com');
    });

    test('empty auth URL parses to null', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'NeedsLogin',
        'AuthURL': '',
      });

      expect(status.authUrl, isNull);
    });

    test('ignores peer inventory in status JSON', () {
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
      expect(status.health, isEmpty);
    });

    test('health warnings', () {
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

    test('all NodeState values parse correctly', () {
      for (final entry in {
        'NoState': NodeState.noState,
        'NeedsLogin': NodeState.needsLogin,
        'NeedsMachineAuth': NodeState.needsMachineAuth,
        'Starting': NodeState.starting,
        'Running': NodeState.running,
        'Stopped': NodeState.stopped,
      }.entries) {
        final status = TailscaleStatus.fromJson({'BackendState': entry.key});
        expect(
          status.state,
          entry.value,
          reason: '${entry.key} should parse to ${entry.value}',
        );
      }
    });

    test('unknown state defaults to noState', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'SomeFutureState',
      });
      expect(status.state, NodeState.noState);
    });
  });

  group('Tailscale API', () {
    test('init rejects empty stateDir', () {
      expect(
        () => Tailscale.init(stateDir: ''),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(
        () => Tailscale.init(stateDir: '   '),
        throwsA(isA<TailscaleUsageException>()),
      );
    });

    test('init accepts a valid state directory', () {
      expect(
        () => Tailscale.init(stateDir: 'build/test-state'),
        returnsNormally,
      );
    });

    test('onStateChange is a broadcast stream', () {
      expect(Tailscale.instance.onStateChange.isBroadcast, isTrue);
    });

    test('onError is a broadcast stream', () {
      expect(Tailscale.instance.onError.isBroadcast, isTrue);
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

  group('TailscaleRuntimeError', () {
    test('parses known runtime error codes', () {
      final error = TailscaleRuntimeError.fromPushPayload({
        'error': 'watch failed',
        'code': 'watcher',
      });

      expect(error.message, 'watch failed');
      expect(error.code, TailscaleRuntimeErrorCode.watcher);
    });

    test('unknown runtime error codes fall back to unknown', () {
      final error = TailscaleRuntimeError.fromPushPayload({
        'error': 'mystery',
        'code': 'something-new',
      });

      expect(error.code, TailscaleRuntimeErrorCode.unknown);
    });

    test('equal runtime errors compare equal', () {
      final a = TailscaleRuntimeError.fromPushPayload({
        'error': 'x',
        'code': 'node',
      });
      final b = TailscaleRuntimeError.fromPushPayload({
        'error': 'x',
        'code': 'node',
      });
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('TailscaleErrorCode', () {
    test('operation exceptions carry code and statusCode', () {
      const err = TailscaleServeException(
        'config moved on',
        code: TailscaleErrorCode.conflict,
        statusCode: 412,
      );
      expect(err.operation, 'serve');
      expect(err.code, TailscaleErrorCode.conflict);
      expect(err.statusCode, 412);
      expect(err.toString(), contains('conflict'));
      expect(err.toString(), contains('config moved on'));
    });

    test('default code is unknown and is omitted from toString', () {
      const err = TailscaleUpException('boom');
      expect(err.code, TailscaleErrorCode.unknown);
      expect(err.toString(), isNot(contains('unknown')));
    });

    test('every namespace has its own exception subtype', () {
      const errors = <TailscaleOperationException>[
        TailscaleUpException('_'),
        TailscaleListenException('_'),
        TailscaleStatusException('_'),
        TailscaleLogoutException('_'),
        TailscaleTaildropException('_'),
        TailscaleServeException('_'),
        TailscalePrefsException('_'),
        TailscaleProfilesException('_'),
        TailscaleExitNodeException('_'),
        TailscaleDiagException('_'),
      ];
      // Distinct runtimeTypes.
      final types = errors.map((e) => e.runtimeType).toSet();
      expect(types.length, errors.length);
    });
  });

  group('value-type equality', () {
    test('TailscaleStatus ==', () {
      const a = TailscaleStatus(
        state: NodeState.running,
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      const b = TailscaleStatus(
        state: NodeState.running,
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      const c = TailscaleStatus(
        state: NodeState.stopped,
        tailscaleIPs: ['100.64.0.1'],
        health: [],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('PeerStatus == includes stableNodeId', () {
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
      final a = PeerStatus.fromJson({...base});
      final b = PeerStatus.fromJson({...base});
      final c = PeerStatus.fromJson({...base, 'ID': 'n2'});
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('PeerIdentity ==', () {
      const a = PeerIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );
      const b = PeerIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('FunnelMetadata ==', () {
      const a = FunnelMetadata(publicSrc: '1.2.3.4:443', sni: 'host.example');
      const b = FunnelMetadata(publicSrc: '1.2.3.4:443', sni: 'host.example');
      const c = FunnelMetadata(publicSrc: '1.2.3.4:443', sni: 'other');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('LoginProfile ==', () {
      const a = LoginProfile(
        id: 'p1',
        userLoginName: 'alice',
        tailnetName: 'example.com',
      );
      const b = LoginProfile(
        id: 'p1',
        userLoginName: 'alice',
        tailnetName: 'example.com',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('FileTarget / WaitingFile ==', () {
      const target = FileTarget(
        nodeId: 'n1',
        hostname: 'peer',
        userLoginName: 'alice',
      );
      const otherTarget = FileTarget(
        nodeId: 'n2',
        hostname: 'peer',
        userLoginName: 'alice',
      );
      expect(target, equals(const FileTarget(
        nodeId: 'n1',
        hostname: 'peer',
        userLoginName: 'alice',
      )));
      expect(target, isNot(equals(otherTarget)));

      const file = WaitingFile(name: 'notes.txt', size: 42);
      expect(file, equals(const WaitingFile(name: 'notes.txt', size: 42)));
      expect(file, isNot(equals(const WaitingFile(name: 'notes.txt', size: 43))));
    });

    test('PingResult ==', () {
      const a = PingResult(latency: Duration(milliseconds: 10), direct: true);
      const b = PingResult(latency: Duration(milliseconds: 10), direct: true);
      const c = PingResult(
        latency: Duration(milliseconds: 10),
        direct: false,
        derpRegion: 'nyc',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('ServeConfig ==', () {
      const a = ServeConfig(etag: 'v1');
      const b = ServeConfig(etag: 'v1');
      const c = ServeConfig(etag: 'v2');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(ServeConfig.empty.etag, isNull);
    });
  });
}
