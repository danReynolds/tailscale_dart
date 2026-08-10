library;

import 'package:tailscale/src/keybay_state_custody.dart';
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  group('Keybay StateStore custody binding', () {
    test('derives the dedicated namespace and freezes entry metadata', () {
      expect(
        deriveKeybayAppId('com.example.myapp'),
        'com.example.myapp.tailscale',
      );
      expect(
        deriveKeybayAppId('Com.Example.MyApp'),
        'Com.Example.MyApp.tailscale',
      );
      expect(stateStoreDekEntry, 'tailscale/state-store/v1/dek');
      expect(stateStoreDekLabel, 'Tailscale node-state encryption key');
    });

    test('accepts exactly the 110-character host appId limit', () {
      final appId = 'a' * 110;
      expect(deriveKeybayAppId(appId), '$appId.tailscale');
      expect(deriveKeybayAppId(appId).length, 120);
    });

    test('rejects identifiers Keybay cannot safely namespace', () {
      for (final appId in <String>[
        '',
        '.',
        '..',
        '---',
        'com.example/other',
        'com.example app',
        'com.example\n',
        'café.example',
        'a' * 111,
      ]) {
        expect(
          () => deriveKeybayAppId(appId),
          throwsA(isA<TailscaleUsageException>()),
          reason: 'must reject an appId of length ${appId.length}',
        );
      }
    });

    test('identity does not resolve or touch Keybay', () {
      var factoryCalls = 0;
      final binding = KeybayStateCustodyBinding(
        hostAppId: 'com.example.myapp',
        storageFactory: ({required appId}) {
          factoryCalls++;
          throw StateError('R4a must not resolve Keybay for $appId.');
        },
      );

      expect(factoryCalls, 0);
      expect(binding.hostAppId, 'com.example.myapp');
      expect(binding.keybayNamespace, 'com.example.myapp.tailscale');
      expect(factoryCalls, 0);
    });
  });
}
