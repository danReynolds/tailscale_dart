/// Low-level tests for `package:tailscale/src/ffi_bindings.dart` —
/// confirms the native library loaded, symbols resolve, and each
/// exported function returns the documented shape when invoked in
/// isolation (before any server startup).
///
/// Public-API lifecycle tests live in `test/lifecycle_test.dart`; this
/// file is intentionally scoped to the binding surface that sits
/// between Dart and Go.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

void main() {
  setUpAll(() {
    // Suppress Go stderr logging during tests.
    native.duneSetLogLevel(0);
  });

  group('symbol resolution', () {
    test('duneStart is callable', () {
      expect(native.duneStart, isNotNull);
    });
  });

  group('duneHasState', () {
    test('returns 0 for nonexistent directory', () {
      final dir =
          '/tmp/tailscale_test_nonexistent_${DateTime.now().millisecondsSinceEpoch}';
      final dirPtr = dir.toNativeUtf8();
      final result = native.duneHasState(dirPtr);
      calloc.free(dirPtr);

      expect(result, 0);
    });

    test('returns 0 for empty directory', () {
      final dir = Directory.systemTemp.createTempSync('tailscale_test_empty_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final dirPtr = dir.path.toNativeUtf8();
      final result = native.duneHasState(dirPtr);
      calloc.free(dirPtr);

      expect(result, 0);
    });
  });

  group('dunePeers (before start)', () {
    test('returns empty array JSON when server not running', () {
      final ptr = native.dunePeers();
      final result = ptr.toDartString();
      native.duneFree(ptr);

      expect(result, '[]');
      expect(jsonDecode(result), isEmpty);
    });
  });

  group('duneStatus (before start)', () {
    test('returns empty object JSON when server not running', () {
      final ptr = native.duneStatus();
      final result = ptr.toDartString();
      native.duneFree(ptr);

      expect(result, '{}');
      expect(jsonDecode(result), isEmpty);
    });
  });

  group('duneStop', () {
    test('does not crash when server not running', () {
      native.duneStop();
    });
  });

  group('duneSetLogLevel', () {
    test('can set to silent without crashing', () {
      native.duneSetLogLevel(0);
    });

    test('can set to info without crashing', () {
      native.duneSetLogLevel(2);
      native.duneSetLogLevel(0);
    });
  });

  group('duneStart error handling', () {
    test('returns valid JSON for unreachable control URL', () {
      final dir = Directory.systemTemp.createTempSync('tailscale_test_start_');
      addTearDown(() {
        native.duneStop();
        dir.deleteSync(recursive: true);
      });

      final hostname = 'test-node'.toNativeUtf8();
      final authKey = 'tskey-fake-key'.toNativeUtf8();
      final controlUrl = 'http://127.0.0.1:1/'.toNativeUtf8();
      final stateDir = dir.path.toNativeUtf8();

      final resultPtr = native.duneStart(
        hostname,
        authKey,
        controlUrl,
        stateDir,
      );
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      calloc.free(hostname);
      calloc.free(authKey);
      calloc.free(controlUrl);
      calloc.free(stateDir);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(
        parsed.containsKey('transportBootstrap') || parsed.containsKey('error'),
        isTrue,
        reason:
            'Expected {"transportBootstrap": {...}} or {"error": "..."}, got: $resultJson',
      );
      if (parsed.containsKey('transportBootstrap')) {
        final bootstrap =
            parsed['transportBootstrap'] as Map<String, dynamic>;
        expect(bootstrap['masterSecretB64'], isA<String>());
        expect((bootstrap['masterSecretB64'] as String), isNotEmpty);
        expect(bootstrap['sessionGenerationIdB64'], isA<String>());
        expect((bootstrap['sessionGenerationIdB64'] as String), isNotEmpty);
        expect(bootstrap['preferredCarrierKind'], isA<String>());
        expect((bootstrap['preferredCarrierKind'] as String), isNotEmpty);
      }
    });
  });

  group('duneListen validation', () {
    test('rejects invalid tailnet port before server startup', () {
      final resultPtr = native.duneListen(0, 0);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('invalid tailnet port'));
    });
  });
}
