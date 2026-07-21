import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  group('TailscaleNode.lastSeen', () {
    Map<String, dynamic> nodeJson(String? lastSeen) => <String, dynamic>{
      'HostName': 'peer',
      'Online': true,
      'LastSeen': ?lastSeen,
    };

    test('is null for the Go zero-time sentinel (online / never tracked)', () {
      // Go marshals an unset time.Time as "0001-01-01T00:00:00Z"; it must not
      // surface as a year-1 DateTime.
      final node = TailscaleNode.fromJson(nodeJson('0001-01-01T00:00:00Z'));
      expect(node.lastSeen, isNull);
    });

    test('is null when the field is absent', () {
      final node = TailscaleNode.fromJson(nodeJson(null));
      expect(node.lastSeen, isNull);
    });

    test('parses a real timestamp', () {
      final node = TailscaleNode.fromJson(nodeJson('2026-07-21T12:00:00Z'));
      expect(node.lastSeen, DateTime.utc(2026, 7, 21, 12));
    });
  });
}
