/// Coverage for the `prefs` namespace value types and wrapper behavior.
library;

import 'package:test/test.dart';
import 'package:tailscale/src/api/prefs.dart' show createPrefs;
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
        autoExitNode: true,
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
        autoExitNode: true,
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
        autoExitNode: true,
        exitNodeId: 'n123',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });

    test('fromJson tolerates missing optional fields', () {
      final prefs = TailscalePrefs.fromJson({
        'advertisedRoutes': ['10.0.0.0/24'],
        'acceptRoutes': true,
        'shieldsUp': false,
        'advertisedTags': ['tag:server'],
        'wantRunning': true,
        'autoUpdate': true,
        'hostname': 'router',
        'autoExitNode': true,
        'exitNodeId': 'n123',
      });

      expect(prefs.advertisedRoutes, ['10.0.0.0/24']);
      expect(prefs.acceptRoutes, isTrue);
      expect(prefs.autoUpdate, isTrue);
      expect(prefs.hostname, 'router');
      expect(prefs.autoExitNode, isTrue);
      expect(prefs.exitNodeId, 'n123');
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

    test('toJson omits unchanged fields and keeps explicit clears', () {
      const update = PrefsUpdate(
        advertisedRoutes: [],
        shieldsUp: false,
        exitNodeId: '',
      );

      expect(update.toJson(), {
        'advertisedRoutes': <String>[],
        'shieldsUp': false,
        'exitNodeId': '',
      });
    });
  });

  group('Prefs wrapper', () {
    test('single-field setters delegate to updateMasked', () async {
      final updates = <PrefsUpdate>[];
      final prefs = createPrefs(
        getFn: () async => const TailscalePrefs(
          advertisedRoutes: [],
          acceptRoutes: false,
          shieldsUp: false,
          advertisedTags: [],
          wantRunning: true,
          autoUpdate: false,
          hostname: 'node',
        ),
        updateFn: (update) async {
          updates.add(update);
          return const TailscalePrefs(
            advertisedRoutes: [],
            acceptRoutes: true,
            shieldsUp: false,
            advertisedTags: [],
            wantRunning: true,
            autoUpdate: false,
            hostname: 'node',
          );
        },
      );

      await prefs.setAcceptRoutes(true);
      await prefs.setAdvertisedRoutes(['10.0.0.0/24']);
      await prefs.setAdvertisedTags(['tag:server']);

      expect(updates, [
        const PrefsUpdate(acceptRoutes: true),
        const PrefsUpdate(advertisedRoutes: ['10.0.0.0/24']),
        const PrefsUpdate(advertisedTags: ['tag:server']),
      ]);
    });
  });
}
