/// Low-level tests for `package:tailscale/src/ffi_bindings.dart` —
/// confirms the native library loaded, symbols resolve, and each
/// exported function returns the documented shape when invoked in
/// isolation (before any server startup).
///
/// Public-API lifecycle tests live in `test/integration/runtime/lifecycle_test.dart`; this
/// file is intentionally scoped to the binding surface that sits
/// between Dart and Go.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

import '../support/process_state_root.dart';

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    configuredStateBaseDir = processIntegrationStateRoot();
    clearProcessIntegrationState(configuredStateBaseDir);
    Tailscale.init(stateDir: configuredStateBaseDir.path);
  });

  tearDownAll(() {
    clearProcessIntegrationState(configuredStateBaseDir);
  });

  group('symbol resolution', () {
    test('duneStart is callable', () {
      expect(native.duneStart, isNotNull);
    });
  });

  group('duneClassifyState', () {
    test('reports absent without creating package state', () {
      clearProcessIntegrationState(configuredStateBaseDir);
      final resultPtr = native.duneClassifyState();
      final result = jsonDecode(resultPtr.toDartString());
      native.duneFree(resultPtr);

      expect(result, {'state': 'absent'});
      expect(
        Directory(
          p.join(configuredStateBaseDir.path, 'tailscale'),
        ).existsSync(),
        isFalse,
      );
    });

    test('recognizes an exact legacy artifact without opening it', () {
      clearProcessIntegrationState(configuredStateBaseDir);
      final ownedDir = Directory(
        p.join(configuredStateBaseDir.path, 'tailscale'),
      )..createSync();
      final artifact = File(p.join(ownedDir.path, 'state.db'))
        ..writeAsStringSync('opaque');
      addTearDown(() => clearProcessIntegrationState(configuredStateBaseDir));

      final resultPtr = native.duneClassifyState();
      final result = jsonDecode(resultPtr.toDartString());
      native.duneFree(resultPtr);

      expect(result, {'state': 'legacy'});
      expect(artifact.readAsStringSync(), 'opaque');
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
      final resultPtr = native.duneStop(999999);
      final result = jsonDecode(resultPtr.toDartString());
      native.duneFree(resultPtr);

      expect(result, containsPair('matched', false));
    });
  });

  group('runtime quarantine', () {
    test('abandon and quiescence exports return JSON receipts', () {
      final abandonPtr = native.duneAbandon(525252);
      final abandon = jsonDecode(abandonPtr.toDartString());
      native.duneFree(abandonPtr);

      final awaitPtr = native.duneAwaitRuntimeQuiescence(525252);
      final quiescence = jsonDecode(awaitPtr.toDartString());
      native.duneFree(awaitPtr);

      expect(abandon, containsPair('token', 525252));
      expect(quiescence, {'ok': true});
    });
  });

  group('duneDebugNodeState', () {
    test('returns a zeroed census when nothing is running', () {
      final ptr = native.duneDebugNodeState();
      final result = ptr.toDartString();
      native.duneFree(ptr);

      final census = jsonDecode(result) as Map<String, dynamic>;
      expect(census['epoch'], isA<int>());
      expect(census['servePublications'], 0);
      expect(census['funnelForwarders'], 0);
      expect(census['httpBindings'], 0);
      expect(census['tcpListeners'], 0);
      expect(census['udpBridges'], 0);
      expect(census['transportCached'], false);
    });
  });

  group('duneUdpCloseBinding', () {
    test('resolves and is a no-op for an unknown binding id', () {
      // Verifies the DuneUdpCloseBinding export resolves end-to-end; an id
      // with no registered bridge is a safe no-op.
      expect(native.duneUdpCloseBinding, isNotNull);
      native.duneUdpCloseBinding(-1);
      native.duneUdpCloseBinding(999999);
    });
  });

  group('duneStart error handling', () {
    test('returns valid JSON for unreachable control URL', () {
      clearProcessIntegrationState(configuredStateBaseDir);
      var startedToken = 0;
      addTearDown(() {
        if (startedToken > 0) {
          final stopPtr = native.duneStop(startedToken);
          native.duneFree(stopPtr);
        }
        clearProcessIntegrationState(configuredStateBaseDir);
      });

      final hostname = 'test-node'.toNativeUtf8();
      final authKey = 'tskey-fake-key'.toNativeUtf8();
      final controlUrl = 'http://127.0.0.1:1/'.toNativeUtf8();
      final hostNetworkSnapshot = '{}'.toNativeUtf8();

      final resultPtr = native.duneStart(
        4242,
        hostname,
        authKey,
        controlUrl,
        0,
        hostNetworkSnapshot,
      );
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      calloc.free(hostname);
      calloc.free(authKey);
      calloc.free(controlUrl);
      calloc.free(hostNetworkSnapshot);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      startedToken = parsed['runtimeToken'] as int? ?? 0;
      expect(
        parsed['ok'] == true || parsed.containsKey('error'),
        isTrue,
        reason: 'Expected {"ok": true} or {"error": "..."}, got: $resultJson',
      );
    });
  });

  group('duneHttpBind validation', () {
    test('rejects invalid tailnet port before server startup', () {
      final resultPtr = native.duneHttpBind(-1);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('invalid tailnet port'));
    });
  });

  group('duneHttpStart validation', () {
    test('returns JSON error before server startup', () {
      final method = 'GET'.toNativeUtf8();
      final url = 'http://100.64.0.1/'.toNativeUtf8();
      final headers = '{}'.toNativeUtf8();
      final resultPtr = native.duneHttpStart(method, url, headers, 0, 1, 5);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(method);
      calloc.free(url);
      calloc.free(headers);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('HttpStart called before Start'));
    });
  });

  group('duneTcpDialFd validation', () {
    test('returns JSON error before server startup', () {
      final host = 'peer'.toNativeUtf8();
      final resultPtr = native.duneTcpDialFd(host, 80, 0);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(host);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('TcpDialFd called before Start'));
    });
  });

  group('duneTcpListenFd validation', () {
    test('returns JSON error before server startup', () {
      final host = ''.toNativeUtf8();
      final resultPtr = native.duneTcpListenFd(12345, host);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(host);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('TcpListenFd called before Start'));
    });
  });

  group('duneTlsListenFd validation', () {
    test('returns JSON error before server startup', () {
      final host = ''.toNativeUtf8();
      final resultPtr = native.duneTlsListenFd(443, host);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(host);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('TlsListenFd called before Start'));
    });
  });

  group('duneUdpBindFd validation', () {
    test('returns JSON error before server startup', () {
      final host = '100.64.0.5'.toNativeUtf8();
      final resultPtr = native.duneUdpBindFd(host, 12345);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(host);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('UdpBindFd called before Start'));
    });
  });

  group('routing control validation', () {
    test('prefs get returns JSON error before server startup', () {
      final resultPtr = native.dunePrefsGet();
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('PrefsGet called before Start'));
    });

    test('exit node suggest returns JSON error before server startup', () {
      final resultPtr = native.duneExitNodeSuggest();
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('ExitNodeSuggest called before Start'));
    });

    test('serve forward returns JSON error before server startup', () {
      final payload = jsonEncode({
        'tailnetPort': 443,
        'localPort': 3000,
        'localAddress': '127.0.0.1',
        'path': '/',
        'https': true,
        'funnel': false,
      }).toNativeUtf8();
      final resultPtr = native.duneServeForward(payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('ServeForward called before Start'));
    });

    test('funnel forward returns JSON error before server startup', () {
      final payload = jsonEncode({
        'tailnetPort': 443,
        'localPort': 3000,
        'localAddress': '127.0.0.1',
        'path': '/',
        'https': true,
        'funnel': true,
      }).toNativeUtf8();
      final resultPtr = native.duneServeForward(payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('FunnelForward called before Start'));
    });

    test('serve clear returns JSON error before server startup', () {
      final payload = jsonEncode({
        'tailnetPort': 443,
        'path': '/',
        'funnel': false,
      }).toNativeUtf8();
      final resultPtr = native.duneServeClear(payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('ServeClear called before Start'));
    });
  });
}
