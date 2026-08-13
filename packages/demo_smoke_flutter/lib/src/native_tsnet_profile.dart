@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:demo_core/demo_core.dart';
import 'package:ffi/ffi.dart';

@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int64)>(
  symbol: 'DuneDebugProfileTsnet',
)
external ffi.Pointer<Utf8> _duneDebugProfileTsnet(
  ffi.Pointer<Utf8> payloadJson,
  int timeoutMillis,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<Utf8>)>(symbol: 'DuneFree')
external void _duneFree(ffi.Pointer<Utf8> pointer);

/// Runs the smoke app's opt-in direct-upstream control on a helper isolate.
///
/// The native symbol exists only when this app enables the package build tag;
/// it is not part of package:tailscale's public API or ordinary native asset.
Future<SpeedTestResult> runNativeTsnetProfile({
  required String host,
  required int port,
  required SpeedTestDirection direction,
  SpeedTestConfig config = canonicalSpeedTestConfig,
  Duration timeout = const Duration(seconds: 45),
}) async {
  config.validate();
  final payload = jsonEncode(<String, Object?>{
    'host': host,
    'port': port,
    'direction': direction.name,
    'config': config.toJson(),
  });
  final result = await Isolate.run(
    () => _runNativeTsnetProfile(payload, timeout.inMilliseconds),
  );
  return SpeedTestResult.fromJson(result);
}

Map<String, Object?> _runNativeTsnetProfile(String payload, int timeoutMillis) {
  final payloadPointer = payload.toNativeUtf8();
  late final ffi.Pointer<Utf8> resultPointer;
  try {
    resultPointer = _duneDebugProfileTsnet(payloadPointer, timeoutMillis);
  } finally {
    calloc.free(payloadPointer);
  }

  late final String encoded;
  try {
    encoded = resultPointer.toDartString();
  } finally {
    _duneFree(resultPointer);
  }
  final decoded = jsonDecode(encoded);
  if (decoded is! Map) {
    throw const FormatException('native tsnet profile returned invalid JSON');
  }
  final result = Map<String, Object?>.from(decoded);
  if (result['error'] case final String message) {
    throw StateError('native tsnet profile failed: $message');
  }
  return result;
}
