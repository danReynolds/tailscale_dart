/// Coverage for the `whois` top-level call and the [TailscaleNodeIdentity]
/// value type it returns.
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

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
