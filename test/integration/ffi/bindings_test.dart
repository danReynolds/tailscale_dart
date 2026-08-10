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
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;
import 'package:tailscale/src/state_custody_coordinator.dart';

import '../support/process_state_root.dart';

void main() {
  late Directory configuredStateBaseDir;

  setUpAll(() {
    configuredStateBaseDir = processIntegrationStateRoot();
    clearProcessIntegrationState(configuredStateBaseDir);
    Tailscale.init(
      stateDir: configuredStateBaseDir.path,
      appId: processIntegrationAppId,
    );
  });

  tearDownAll(() async {
    await forgetProcessIntegrationState(configuredStateBaseDir);
  });

  group('symbol resolution', () {
    test('duneStart is callable', () {
      expect(native.duneStart, isNotNull);
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

      final retirePtr = native.duneRetireAbandonedRuntimeToken(525252);
      final retirement = jsonDecode(retirePtr.toDartString());
      native.duneFree(retirePtr);

      final awaitPtr = native.duneAwaitRuntimeQuiescence(525252);
      final quiescence = jsonDecode(awaitPtr.toDartString());
      native.duneFree(awaitPtr);

      expect(abandon, containsPair('token', 525252));
      expect(retirement, {'ok': true});
      expect(quiescence, {'ok': true});
    });

    test('persistent custody symbols accept an arbitrary binary DEK', () {
      clearProcessIntegrationState(configuredStateBaseDir);
      const token = 525253;
      var completed = false;
      addTearDown(() {
        if (completed) return;
        final abandon = _decodeAndFree(native.duneAbandon(token));
        if (abandon['custodyHeld'] == true) {
          _decodeAndFree(native.duneFinishCustody(token, 1));
        }
        _decodeAndFree(native.duneAwaitRuntimeQuiescence(token));
      });
      final begin = _decodeAndFree(
        native.duneBeginPersistentPreparation(token),
      );
      expect(begin, {'ok': true});

      final active = _decodeAndFree(native.duneMarkCustodyActive(token));
      expect(active, {'ok': true});
      final invalid = calloc<ffi.Uint8>(31);
      try {
        final rejected = _decodeAndFree(
          native.duneSupplyPreparedDek(token, invalid, 31),
        );
        expect(rejected, containsPair('code', 'invalidStateKey'));
      } finally {
        invalid.asTypedList(31).fillRange(0, 31, 0);
        calloc.free(invalid);
      }
      final key = Uint8List.fromList(
        List<int>.generate(32, (index) => index * 11 & 0xff),
      );
      key[0] = 0;
      key[key.length - 1] = 0xff;
      supplyTransferredDekToNative(
        token: token,
        transferred: TransferableTypedData.fromList(<Uint8List>[key]),
      );

      final abandon = _decodeAndFree(native.duneAbandon(token));
      expect(abandon, containsPair('custodyHeld', true));
      expect(abandon, containsPair('custodyDisposition', 'none'));
      final finish = _decodeAndFree(native.duneFinishCustody(token, 1));
      expect(finish, {'ok': true});
      final quiescence = _decodeAndFree(
        native.duneAwaitRuntimeQuiescence(token),
      );
      expect(quiescence, {'ok': true});
      completed = true;
      expect(
        Directory(
          p.join(configuredStateBaseDir.path, 'tailscale'),
        ).existsSync(),
        isFalse,
      );
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
      expect(census, isNot(contains('funnelForwarders')));
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
        1,
        hostNetworkSnapshot,
        30000,
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

  group('duneDataPlaneReady', () {
    test('reports not ready for unowned runtime tokens', () {
      // The leaf readiness probe behind the HTTP send fast path: before any
      // server startup no token can resolve to a bootstrapped runtime, so the
      // direct-call path must stay closed.
      expect(native.duneDataPlaneReady(0), 0);
      expect(native.duneDataPlaneReady(999999), 0);
    });
  });

  group('duneHttpStart validation', () {
    test('returns JSON error before server startup', () {
      final method = 'GET'.toNativeUtf8();
      final url = 'http://100.64.0.1/'.toNativeUtf8();
      final headers = '{}'.toNativeUtf8();
      final resultPtr = native.duneHttpStart(
        999999,
        method,
        url,
        headers,
        0,
        1,
        5,
      );
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
    test('rejects an unowned runtime token before server startup', () {
      final host = 'peer'.toNativeUtf8();
      final resultPtr = native.duneTcpDialFd(999999, host, 80, 0);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(host);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('TcpDialFd captured runtime 999999'));
      expect(parsed['code'], 'staleRuntime');
    });
  });

  group('duneDiagPing validation', () {
    test('rejects an unowned runtime token before LocalAPI dispatch', () {
      final ip = '100.64.0.1'.toNativeUtf8();
      final pingType = 'disco'.toNativeUtf8();
      final resultPtr = native.duneDiagPing(999999, ip, 0, pingType);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(ip);
      calloc.free(pingType);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('DiagPing captured runtime 999999'));
      expect(parsed['code'], 'staleRuntime');
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
      final resultPtr = native.duneServeForward(0, payload);
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
      final resultPtr = native.duneServeForward(0, payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], contains('ServeForward called before Start'));
    });

    test(
      'publication acknowledgement symbols preserve exact-token semantics',
      () {
        final acknowledgePtr = native.duneAcknowledgePublication(91, 7, 3);
        final acknowledgeJson = acknowledgePtr.toDartString();
        native.duneFree(acknowledgePtr);
        final acknowledge = jsonDecode(acknowledgeJson) as Map<String, dynamic>;
        expect(acknowledge['code'], 'staleRuntime');

        final compensatePtr = native.duneFailPublicationDelivery(91);
        final compensateJson = compensatePtr.toDartString();
        native.duneFree(compensatePtr);
        expect(jsonDecode(compensateJson), {'ok': true});
      },
    );

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

    test('stale exact publication close is an idle no-op', () {
      final payload = jsonEncode({
        'tailnetPort': 443,
        'path': '/',
        'funnel': false,
        'generation': 91,
        'mappingToken': 7,
      }).toNativeUtf8();
      final resultPtr = native.duneServeClear(payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed, containsPair('ok', true));
    });

    test('partial exact publication identity is rejected', () {
      final payload = jsonEncode({
        'tailnetPort': 443,
        'path': '/',
        'funnel': false,
        'generation': 91,
      }).toNativeUtf8();
      final resultPtr = native.duneServeClear(payload);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);
      calloc.free(payload);

      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      expect(parsed['error'], isNotNull);
    });
  });
}

Map<String, dynamic> _decodeAndFree(ffi.Pointer<Utf8> pointer) {
  try {
    return jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
  } finally {
    native.duneFree(pointer);
  }
}
