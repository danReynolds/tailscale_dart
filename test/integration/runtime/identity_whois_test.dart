/// Coverage for the `whois` top-level call and the [TailscaleNodeIdentity]
/// value type it returns.
@TestOn('mac-os || linux')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

/// Spawned isolate body: echoes the identity it receives back to [reply],
/// mirroring how the TCP accept loop hands a decoded identity to its parent.
void _echoIdentity(List<Object?> args) {
  final reply = args[0] as SendPort;
  final identity = args[1] as TailscaleNodeIdentity?;
  reply.send(identity);
}

void main() {
  group('TailscaleNodeIdentity value type', () {
    test('==', () {
      const a = TailscaleNodeIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );
      const b = TailscaleNodeIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );
      const different = TailscaleNodeIdentity(
        nodeId: 'n2',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });

    test('toString summarizes identity fields', () {
      const identity = TailscaleNodeIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:server'],
        tailscaleIPs: ['100.64.0.2'],
      );

      final s = identity.toString();
      expect(s, contains('n1'));
      expect(s, contains('h'));
      expect(s, contains('alice@example.com'));
      expect(s, contains('tag:server'));
    });
  });

  group('TailscaleNodeIdentity.fromJson', () {
    // This decoder is shared by whois and by the accept-time identity
    // attached to inbound connections, so it must not consult `found`.
    test('maps all fields from a native identity object', () {
      final identity = TailscaleNodeIdentity.fromJson(const {
        'nodeId': 'nABC123',
        'hostName': 'peer-1',
        'userLoginName': 'alice@example.com',
        'tags': ['tag:server', 'tag:prod'],
        'tailscaleIPs': ['100.64.0.2', 'fd7a:115c:a1e0::2'],
      });

      expect(identity.nodeId, 'nABC123');
      expect(identity.hostName, 'peer-1');
      expect(identity.userLoginName, 'alice@example.com');
      expect(identity.tags, ['tag:server', 'tag:prod']);
      expect(identity.tailscaleIPs, ['100.64.0.2', 'fd7a:115c:a1e0::2']);
    });

    test('defaults missing or mistyped fields to empty values', () {
      final identity = TailscaleNodeIdentity.fromJson(const {'nodeId': 'n1'});

      expect(identity.nodeId, 'n1');
      expect(identity.hostName, isEmpty);
      expect(identity.userLoginName, isEmpty);
      expect(identity.tags, isEmpty);
      expect(identity.tailscaleIPs, isEmpty);
    });

    test('keeps only string tags and ips', () {
      final identity = TailscaleNodeIdentity.fromJson(const {
        'nodeId': 'n1',
        'tags': ['tag:ok', 7, null],
        'tailscaleIPs': ['100.64.0.2', 42],
      });

      expect(identity.tags, ['tag:ok']);
      expect(identity.tailscaleIPs, ['100.64.0.2']);
    });

    // The TCP accept loop decodes identity inside a spawned isolate and
    // sends the value to its parent over a SendPort. That send only works
    // if TailscaleNodeIdentity is isolate-transferable; guard it so a
    // future non-sendable field can't silently break inbound identity.
    test('survives an isolate SendPort round-trip', () async {
      const sent = TailscaleNodeIdentity(
        nodeId: 'nABC123',
        hostName: 'peer-1',
        userLoginName: 'alice@example.com',
        tags: ['tag:server', 'tag:prod'],
        tailscaleIPs: ['100.64.0.2', 'fd7a:115c:a1e0::2'],
      );

      final reply = ReceivePort();
      await Isolate.spawn(_echoIdentity, <Object?>[reply.sendPort, sent]);
      final received = await reply.first.timeout(const Duration(seconds: 5));
      reply.close();

      expect(received, isA<TailscaleNodeIdentity>());
      expect(received, equals(sent));
    });
  });

  group('Tailscale.whois', () {
    late Directory stateDir;

    setUpAll(() {
      native.duneSetLogLevel(0);
      stateDir = Directory.systemTemp.createTempSync('tailscale_whois_');
      Tailscale.init(stateDir: stateDir.path);
    });

    tearDownAll(() async {
      try {
        await Tailscale.instance.down();
      } catch (_) {}
      native.duneStop();
      if (stateDir.existsSync()) {
        stateDir.deleteSync(recursive: true);
      }
    });

    test('rejects obviously-invalid IPs', () async {
      await expectLater(
        Tailscale.instance.whois('not-an-ip'),
        throwsA(isA<TailscaleException>()),
      );
    });

    test('before up() throws', () async {
      await expectLater(
        Tailscale.instance.whois('100.64.0.5'),
        throwsA(isA<TailscaleException>()),
      );
    });
  });
}
