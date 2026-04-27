/// Coverage for the `funnel` namespace. Phase 2 landed [FunnelMetadata]
/// and the `Socket.funnel` extension; the rest of the namespace
/// (`funnel.bind`) arrives in a later phase and will add tests here.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('FunnelMetadata', () {
    test('==', () {
      const a = FunnelMetadata(publicSrc: '1.2.3.4:443', sni: 'host.example');
      const b = FunnelMetadata(publicSrc: '1.2.3.4:443', sni: 'host.example');
      const differentSni = FunnelMetadata(
        publicSrc: '1.2.3.4:443',
        sni: 'other',
      );
      const nullSni = FunnelMetadata(publicSrc: '1.2.3.4:443');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentSni)));
      expect(a, isNot(equals(nullSni)));
    });
  });
}
