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
