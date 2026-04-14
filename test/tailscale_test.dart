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

      expect(status.nodeStatus, NodeStatus.running);
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

    test('parses PeerStatus list snapshots', () {
      final peers = PeerStatus.listFromJson([
        {
          'PublicKey': 'abc123',
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
      expect(peers.last.online, isFalse);
    });

    test('handles empty/minimal JSON', () {
      final status = TailscaleStatus.fromJson({});

      expect(status.nodeStatus, NodeStatus.noState);
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

      expect(status.nodeStatus, NodeStatus.needsLogin);
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
      expect(TailscaleStatus.stopped.nodeStatus, NodeStatus.stopped);
      expect(TailscaleStatus.stopped.isRunning, isFalse);
    });

    test('all NodeStatus values parse correctly', () {
      for (final entry in {
        'NoState': NodeStatus.noState,
        'NeedsLogin': NodeStatus.needsLogin,
        'NeedsMachineAuth': NodeStatus.needsMachineAuth,
        'Starting': NodeStatus.starting,
        'Running': NodeStatus.running,
        'Stopped': NodeStatus.stopped,
      }.entries) {
        final status = TailscaleStatus.fromJson({'BackendState': entry.key});
        expect(
          status.nodeStatus,
          entry.value,
          reason: '${entry.key} should parse to ${entry.value}',
        );
      }
    });

    test('unknown state defaults to noState', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'SomeFutureState',
      });
      expect(status.nodeStatus, NodeStatus.noState);
    });
  });

  group('Tailscale API', () {
    test('up timeout parameter has a default', () {
      final tsnet = Tailscale.instance;
      expect(tsnet.up, isA<Function>());
    });

    test('peers exposes a snapshot method', () {
      final tsnet = Tailscale.instance;
      expect(tsnet.peers, isA<Function>());
    });

    test(
      'init is idempotent for identical config and rejects config drift',
      () {
        Tailscale.init(
          stateDir: 'build/test-state',
          logLevel: TailscaleLogLevel.info,
        );

        expect(
          () => Tailscale.init(
            stateDir: 'build/./test-state/',
            logLevel: TailscaleLogLevel.info,
          ),
          returnsNormally,
        );

        expect(
          () => Tailscale.init(
            stateDir: 'build/other-state',
            logLevel: TailscaleLogLevel.info,
          ),
          throwsA(isA<TailscaleUsageException>()),
        );
      },
    );

    test('statusChanges exposes a broadcast stream', () {
      final tsnet = Tailscale.instance;
      expect(tsnet.onStatusChange.isBroadcast, isTrue);
    });

    test('runtimeErrors exposes a broadcast stream', () {
      final tsnet = Tailscale.instance;
      expect(tsnet.onError.isBroadcast, isTrue);
    });

    test('worker events do not consume queued RPC responses', () {
      final tsnet = Tailscale.forTest();

      expect(
        tsnet.debugWorkerEventDoesNotConsumePendingResponseForTest(),
        isTrue,
      );
    });

    test('worker exit fails queued RPC responses', () async {
      final tsnet = Tailscale.forTest();

      await expectLater(
        tsnet.debugWorkerExitFailsPendingResponseForTest(),
        completion(isTrue),
      );
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
  });
}
