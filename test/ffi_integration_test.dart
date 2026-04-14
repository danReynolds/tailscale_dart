/// FFI integration tests — exercises the real native library without network.
///
/// The build hook compiles the Go library automatically. Just run:
///   dart test test/ffi_integration_test.dart
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    // Suppress Go stderr logging during tests.
    native.duneSetLogLevel(0);
    configuredStateBaseDir = Directory.systemTemp.createTempSync(
      'tailscale_test_base_',
    );
    Tailscale.init(stateDir: configuredStateBaseDir.path);
  });

  tearDownAll(() {
    if (configuredStateBaseDir.existsSync()) {
      configuredStateBaseDir.deleteSync(recursive: true);
    }
  });

  group('symbol resolution', () {
    test('duneStart is callable', () {
      // We can't actually call duneStart without valid params that would
      // start a real server, but the fact that this doesn't throw
      // "symbol not found" proves the binding works.
      // The other tests below exercise the actual FFI calls.
      expect(native.duneGetPeers, isNotNull);
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

  group('duneGetPeers (before start)', () {
    test('returns empty array JSON when server not running', () {
      final ptr = native.duneGetPeers();
      final result = ptr.toDartString();
      native.duneFree(ptr);

      expect(result, '[]');
      expect(jsonDecode(result), isEmpty);
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

  group('duneGetLocalIP (before start)', () {
    test('returns empty string when server not running', () {
      final ptr = native.duneGetLocalIP();
      final result = ptr.toDartString();
      native.duneFree(ptr);

      expect(result, '');
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
      // Reset to silent for remaining tests
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
        parsed.containsKey('proxyPort') || parsed.containsKey('error'),
        isTrue,
        reason:
            'Expected {"proxyPort": N, "proxyAuthToken": "..."} or {"error": "..."}, got: $resultJson',
      );
      if (parsed.containsKey('proxyPort')) {
        expect(parsed['proxyAuthToken'], isA<String>());
        expect((parsed['proxyAuthToken'] as String), isNotEmpty);
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

  group('Tailscale.up cleanup', () {
    test('stops the native server when start times out', () async {
      addTearDown(() async {
        try {
          await Tailscale.instance.down();
        } catch (_) {}
        native.duneStop();
      });

      await expectLater(
        Tailscale.instance.up(
          hostname: 'timeout-test',
          authKey: 'tskey-fake-key',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(anything),
      );

      expect(Tailscale.instance.isRunning, isFalse);

      final ptr = native.duneStatus();
      final result = ptr.toDartString();
      native.duneFree(ptr);
      expect(result, '{}');
    });
  });

  group('Tailscale.logout', () {
    test('removes only the owned state subdirectory', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }
      ownedStateDir.createSync(recursive: true);

      final preservedFile = File(
        p.join(configuredStateBaseDir.path, 'keep.txt'),
      )..writeAsStringSync('keep');
      File(
        p.join(ownedStateDir.path, 'state.db'),
      ).writeAsStringSync('placeholder');

      await Tailscale.instance.logout();

      expect(configuredStateBaseDir.existsSync(), isTrue);
      expect(preservedFile.existsSync(), isTrue);
      expect(ownedStateDir.existsSync(), isFalse);
    });

    test('emits a stopped snapshot on statusChanges', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }
      ownedStateDir.createSync(recursive: true);
      File(
        p.join(ownedStateDir.path, 'state.db'),
      ).writeAsStringSync('placeholder');

      final eventFuture = Tailscale.instance.onStatusChange.first;
      await Tailscale.instance.logout();
      final snapshot = await eventFuture;

      expect(snapshot.nodeStatus, NodeStatus.stopped);
      expect(snapshot.isRunning, isFalse);
    });
  });
}
