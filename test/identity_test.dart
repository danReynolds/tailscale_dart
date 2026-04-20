/// Coverage for the `whois` top-level call and the [PeerIdentity]
/// value type it returns. `whois` itself is a stub in Phase 2; this
/// file currently just covers the value type's equality contract.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('PeerIdentity', () {
    test('==', () {
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
      const differentTags = PeerIdentity(
        nodeId: 'n1',
        hostName: 'h',
        userLoginName: 'alice@example.com',
        tags: ['tag:client'],
        tailscaleIPs: ['100.64.0.2'],
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentTags)));
    });
  });
}
