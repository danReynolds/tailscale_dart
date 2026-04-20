/// Coverage for the `whois` top-level call and the [PeerIdentity]
/// value type it returns. `whois` itself is a stub in Phase 2; this
/// file will grow as later phases wire up LocalAPI-backed lookups.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('PeerIdentity', () {
    test('toString summarizes identity fields', () {
      const identity = PeerIdentity(
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
}
