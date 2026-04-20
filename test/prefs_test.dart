/// Coverage for the `prefs` namespace. The methods are still stubs in
/// Phase 3, but the immutable value types are already part of the
/// stabilized surface and should behave like proper values.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('TailscalePrefs', () {
    test('==', () {
      const a = TailscalePrefs(
        advertisedRoutes: ['10.0.0.0/24'],
        acceptRoutes: true,
        shieldsUp: false,
        advertisedTags: ['tag:server'],
        wantRunning: true,
        autoUpdate: false,
        hostname: 'app',
        exitNodeId: 'n123',
      );
      const b = TailscalePrefs(
        advertisedRoutes: ['10.0.0.0/24'],
        acceptRoutes: true,
        shieldsUp: false,
        advertisedTags: ['tag:server'],
        wantRunning: true,
        autoUpdate: false,
        hostname: 'app',
        exitNodeId: 'n123',
      );
      const different = TailscalePrefs(
        advertisedRoutes: ['10.0.1.0/24'],
        acceptRoutes: true,
        shieldsUp: false,
        advertisedTags: ['tag:server'],
        wantRunning: true,
        autoUpdate: false,
        hostname: 'app',
        exitNodeId: 'n123',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });

  group('PrefsUpdate', () {
    test('==', () {
      const a = PrefsUpdate(
        advertisedRoutes: ['10.0.0.0/24'],
        acceptRoutes: true,
        advertisedTags: ['tag:server'],
        exitNodeId: '',
      );
      const b = PrefsUpdate(
        advertisedRoutes: ['10.0.0.0/24'],
        acceptRoutes: true,
        advertisedTags: ['tag:server'],
        exitNodeId: '',
      );
      const different = PrefsUpdate(
        advertisedRoutes: ['10.0.0.0/24'],
        acceptRoutes: false,
        advertisedTags: ['tag:server'],
        exitNodeId: '',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });
}
