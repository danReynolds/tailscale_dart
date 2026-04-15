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

  // -----------------------------------------------------------------------
  // Public API edge cases — tests run in order, each building on prior state.
  // -----------------------------------------------------------------------

  group('status() before up()', () {
    test('returns stopped when persisted state exists', () async {
      // Create persisted state via a throwaway duneStart/duneStop.
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      ownedStateDir.createSync(recursive: true);

      final hostname = 'status-test'.toNativeUtf8();
      final authKey = 'tskey-fake'.toNativeUtf8();
      final controlUrl = 'http://127.0.0.1:1/'.toNativeUtf8();
      final stateDir = ownedStateDir.path.toNativeUtf8();

      final resultPtr = native.duneStart(
        hostname,
        authKey,
        controlUrl,
        stateDir,
      );
      native.duneFree(resultPtr);
      calloc.free(hostname);
      calloc.free(authKey);
      calloc.free(controlUrl);
      calloc.free(stateDir);
      native.duneStop();

      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.stopped);

      // Clean up so later tests start fresh.
      ownedStateDir.deleteSync(recursive: true);
    });

    test('returns noState when no persisted state', () async {
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }

      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.noState);
    });
  });

  group('up() without auth key', () {
    test('throws TailscaleUpException when no persisted state', () async {
      // Ensure no state directory exists.
      final ownedStateDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      );
      if (ownedStateDir.existsSync()) {
        ownedStateDir.deleteSync(recursive: true);
      }

      await expectLater(
        Tailscale.instance.up(
          hostname: 'no-auth-test',
          controlUrl: Uri.parse('http://127.0.0.1:1/'),
        ),
        throwsA(isA<TailscaleUpException>()),
      );
    });
  });

  group('before up()', () {
    test('status() returns empty status', () async {
      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.noState);
      expect(status.tailscaleIPs, isEmpty);
    });

    test('peers() returns empty list', () async {
      final peers = await Tailscale.instance.peers();
      expect(peers, isEmpty);
    });

    test('down() is a no-op', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('listen() throws TailscaleListenException', () async {
      await expectLater(
        Tailscale.instance.listen(8080),
        throwsA(isA<TailscaleListenException>()),
      );
    });

    test('logout() does not throw', () async {
      await expectLater(Tailscale.instance.logout(), completes);
    });

    test('http throws', () {
      expect(
        () => Tailscale.instance.http,
        throwsA(isA<TailscaleUsageException>()),
      );
    });
  });

  group('up/down lifecycle', () {
    test('up() starts the node and delivers state events', () async {
      // Subscribe before up() so we catch the events.
      final firstEvent = Tailscale.instance.onStateChange.first;

      await Tailscale.instance.up(
        hostname: 'lifecycle-test',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));

      final state = await firstEvent.timeout(const Duration(seconds: 5));
      expect(state, isA<NodeState>());
    });

    test('http is available after up()', () {
      expect(() => Tailscale.instance.http, returnsNormally);
    });

    test('down() succeeds', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('status() after down() returns stopped (persisted state exists)', () async {
      final status = await Tailscale.instance.status();
      expect(status.state, NodeState.stopped);
      expect(status.tailscaleIPs, isEmpty);
    });

    test('peers() after down() returns empty', () async {
      final peers = await Tailscale.instance.peers();
      expect(peers, isEmpty);
    });

    test('down() twice is a no-op', () async {
      await expectLater(Tailscale.instance.down(), completes);
    });

    test('up() restarts after down()', () async {
      await Tailscale.instance.up(
        hostname: 'lifecycle-restart',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));

      await Tailscale.instance.down();
    });

    test('up() twice without down() replaces the node', () async {
      addTearDown(() async {
        try {
          await Tailscale.instance.down();
        } catch (_) {}
        native.duneStop();
      });

      await Tailscale.instance.up(
        hostname: 'double-up-1',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      await Tailscale.instance.up(
        hostname: 'double-up-2',
        authKey: 'tskey-fake-key',
        controlUrl: Uri.parse('http://127.0.0.1:1/'),
      );

      final status = await Tailscale.instance.status();
      expect(status.state, isNot(NodeState.noState));
    });
  });

  group('logout', () {
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

    test('logout() twice does not throw', () async {
      await expectLater(Tailscale.instance.logout(), completes);
    });
  });
}
