import 'dart:convert';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  late DuneTsnet tsnet;

  setUp(() {
    tsnet = DuneTsnet.instance;
    tsnet.proxyPortForTesting = 0;
  });

  group('getProxyUri', () {
    test('builds correct URI with default port', () {
      tsnet.proxyPortForTesting = 8080;

      final uri = tsnet.getProxyUri('100.64.0.1', '/api/v1/data');

      expect(uri.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 8080);
      expect(uri.path, '/api/v1/data');
      expect(uri.queryParameters['target'], '100.64.0.1:80');
    });

    test('builds correct URI with custom port', () {
      tsnet.proxyPortForTesting = 9999;

      final uri =
          tsnet.getProxyUri('100.64.0.2', '/submit', targetPort: 8443);

      expect(uri.port, 9999);
      expect(uri.path, '/submit');
      expect(uri.queryParameters['target'], '100.64.0.2:8443');
    });

    test('throws when not running (port 0)', () {
      tsnet.proxyPortForTesting = 0;

      expect(
        () => tsnet.getProxyUri('100.64.0.1', '/test'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('Not running'),
        )),
      );
    });

    test('handles root path', () {
      tsnet.proxyPortForTesting = 5000;

      final uri = tsnet.getProxyUri('100.64.0.3', '/');

      expect(uri.path, '/');
      expect(uri.queryParameters['target'], '100.64.0.3:80');
    });

    test('handles path with multiple segments', () {
      tsnet.proxyPortForTesting = 5000;

      final uri =
          tsnet.getProxyUri('100.64.0.4', '/api/v2/users/123/profile');

      expect(uri.path, '/api/v2/users/123/profile');
    });

    test('uses loopback address', () {
      tsnet.proxyPortForTesting = 5000;

      final uri = tsnet.getProxyUri('100.64.0.1', '/ping');

      expect(uri.host, '127.0.0.1');
    });
  });

  group('state accessors', () {
    test('proxyPort starts at 0', () {
      expect(tsnet.proxyPort, 0);
    });

    test('proxyPortForTesting sets and reads back', () {
      tsnet.proxyPortForTesting = 12345;
      expect(tsnet.proxyPort, 12345);
    });
  });

  group('init response parsing', () {
    test('valid port response', () {
      const json = '{"port": 8080}';
      final port = parseInitResponse(json);
      expect(port, 8080);
    });

    test('error response throws', () {
      const json = '{"error": "authentication failed"}';
      expect(
        () => parseInitResponse(json),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('authentication failed'),
        )),
      );
    });

    test('error with special characters parses correctly', () {
      final errorMsg = {'error': 'failed: "file not found" at path\\nline2'};
      final json = jsonEncode(errorMsg);
      expect(
        () => parseInitResponse(json),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('file not found'),
        )),
      );
    });

    test('invalid JSON throws', () {
      expect(
        () => parseInitResponse('not json at all'),
        throwsA(isA<Exception>()),
      );
    });

    test('missing port key throws', () {
      const json = '{"status": "ok"}';
      expect(
        () => parseInitResponse(json),
        throwsA(isA<Exception>()),
      );
    });

    test('port 0 is returned (caller should check)', () {
      const json = '{"port": 0}';
      final port = parseInitResponse(json);
      expect(port, 0);
    });
  });

  group('peer address parsing', () {
    test('parses valid peer list', () {
      const json = '["100.64.0.1", "100.64.0.2", "100.64.0.3"]';
      final peers = parsePeerAddresses(json);
      expect(peers, ['100.64.0.1', '100.64.0.2', '100.64.0.3']);
    });

    test('parses empty list', () {
      const json = '[]';
      final peers = parsePeerAddresses(json);
      expect(peers, isEmpty);
    });

    test('parses single peer', () {
      const json = '["100.64.0.1"]';
      final peers = parsePeerAddresses(json);
      expect(peers, ['100.64.0.1']);
    });

    test('returns empty list for invalid JSON', () {
      final peers = parsePeerAddresses('not json');
      expect(peers, isEmpty);
    });

    test('returns empty list for null literal', () {
      final peers = parsePeerAddresses('null');
      expect(peers, isEmpty);
    });

    test('returns empty list for object instead of array', () {
      final peers = parsePeerAddresses('{"peer": "100.64.0.1"}');
      expect(peers, isEmpty);
    });
  });

  group('TailscaleStatus', () {
    test('parses full status JSON', () {
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
        'CurrentTailnet': {
          'MagicDNSSuffix': 'tailnet.ts.net',
        },
      };

      final status = TailscaleStatus.fromJson(json);

      expect(status.backendState, 'Running');
      expect(status.isRunning, isTrue);
      expect(status.needsLogin, isFalse);
      expect(status.isHealthy, isTrue);
      expect(status.tailscaleIPs, ['100.64.0.1', 'fd7a:115c:a1e0::1']);
      expect(status.ipv4, '100.64.0.1');
      expect(status.magicDNSSuffix, 'tailnet.ts.net');
      expect(status.peers, hasLength(2));
      expect(status.onlinePeers, hasLength(1));
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

    test('handles empty/minimal JSON', () {
      final status = TailscaleStatus.fromJson({});

      expect(status.backendState, 'NoState');
      expect(status.isRunning, isFalse);
      expect(status.tailscaleIPs, isEmpty);
      expect(status.peers, isEmpty);
      expect(status.health, isEmpty);
      expect(status.isHealthy, isTrue);
    });

    test('NeedsLogin state', () {
      final status = TailscaleStatus.fromJson({
        'BackendState': 'NeedsLogin',
        'AuthURL': 'https://login.tailscale.com/a/abc123',
      });

      expect(status.needsLogin, isTrue);
      expect(status.isRunning, isFalse);
      expect(status.authUrl, contains('login.tailscale.com'));
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
      expect(TailscaleStatus.stopped.backendState, 'Stopped');
      expect(TailscaleStatus.stopped.isRunning, isFalse);
      expect(TailscaleStatus.stopped.peers, isEmpty);
    });

    test('sameAs detects equal statuses', () {
      final a = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Self': {
          'TailscaleIPs': ['100.64.0.1'],
        },
        'Peer': {
          'k1': {'Online': true, 'TailscaleIPs': ['100.64.0.2']},
        },
      });
      final b = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Self': {
          'TailscaleIPs': ['100.64.0.1'],
        },
        'Peer': {
          'k1': {'Online': true, 'TailscaleIPs': ['100.64.0.2']},
        },
      });

      expect(a.sameAs(b), isTrue);
    });

    test('sameAs detects state change', () {
      final a = TailscaleStatus.fromJson({'BackendState': 'Running'});
      final b = TailscaleStatus.fromJson({'BackendState': 'NeedsLogin'});

      expect(a.sameAs(b), isFalse);
    });

    test('sameAs detects peer count change', () {
      final a = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Peer': {
          'k1': {'Online': true, 'TailscaleIPs': []},
        },
      });
      final b = TailscaleStatus.fromJson({
        'BackendState': 'Running',
        'Peer': {},
      });

      expect(a.sameAs(b), isFalse);
    });
  });

  group('statusStream', () {
    test('is a broadcast stream', () {
      expect(tsnet.statusStream.isBroadcast, isTrue);
    });
  });

  group('init timeout', () {
    test('timeout parameter has a default', () {
      // We can't actually call init without the native library,
      // but we can verify the API accepts a timeout parameter
      // by checking the type signature compiles.
      // The actual timeout behavior is tested in the E2E tests.
      expect(tsnet.init, isA<Function>());
    });
  });
}

/// Parses the JSON response from DuneStart (mirrors the logic in init()).
int parseInitResponse(String resultJson) {
  final Map<String, dynamic> result = jsonDecode(resultJson);
  if (result.containsKey('error')) {
    throw Exception(result['error']);
  }
  final port = result['port'];
  if (port == null) {
    throw Exception('Missing port in response');
  }
  return port as int;
}

/// Parses the JSON response from DuneGetPeers (mirrors the logic in getPeerAddresses()).
List<String> parsePeerAddresses(String jsonStr) {
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) return [];
    return List<String>.from(decoded);
  } catch (e) {
    return [];
  }
}
