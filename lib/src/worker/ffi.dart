part of 'worker.dart';

String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

TailscaleStatus _loadStatusSnapshot() {
  try {
    final parsed = Map<String, dynamic>.from(
      jsonDecode(_callNativeString(native.duneStatus)) as Map<String, dynamic>,
    );
    final error = parsed['error'] as String?;
    if (error != null) {
      throw TailscaleStatusException(error);
    }
    return TailscaleStatus.fromJson(parsed);
  } catch (error) {
    if (error is TailscaleStatusException) {
      rethrow;
    }
    throw TailscaleStatusException(
      'Failed to decode native Tailscale status.',
      cause: error,
    );
  }
}

List<PeerStatus> _loadPeerSnapshot() {
  try {
    final decoded = jsonDecode(_callNativeString(native.dunePeers));
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'] as String?;
      if (error != null) {
        throw TailscaleStatusException(error);
      }
    }

    if (decoded is! List<dynamic>) {
      throw const TailscaleStatusException(
        'Failed to decode native Tailscale peers.',
      );
    }

    return PeerStatus.listFromJson(decoded);
  } catch (error) {
    if (error is TailscaleStatusException) {
      rethrow;
    }
    throw TailscaleStatusException(
      'Failed to decode native Tailscale peers.',
      cause: error,
    );
  }
}

final class _NativeStartResult {
  const _NativeStartResult({
    required this.proxyPort,
    required this.proxyAuthToken,
  });

  final int proxyPort;
  final String proxyAuthToken;
}

Map<String, dynamic> _decodeNativeMapResult(String json) {
  return Map<String, dynamic>.from(jsonDecode(json) as Map<String, dynamic>);
}

_NativeStartResult _startNativeRuntime({
  required String hostname,
  required String authKey,
  required String controlUrl,
  required String stateDir,
}) {
  final p1 = hostname.toNativeUtf8();
  final p2 = authKey.toNativeUtf8();
  final p3 = controlUrl.toNativeUtf8();
  final p4 = stateDir.toNativeUtf8();

  try {
    final result = _decodeNativeMapResult(
      _callNativeString(() {
        return native.duneStart(p1, p2, p3, p4);
      }),
    );

    final error = result['error'] as String?;
    if (error != null) {
      throw TailscaleUpException(error);
    }

    final proxyPort = result['proxyPort'] as int? ?? 0;
    final proxyAuthToken = result['proxyAuthToken'] as String?;
    if (proxyPort == 0 || proxyAuthToken == null || proxyAuthToken.isEmpty) {
      throw const TailscaleUpException(
        'Failed to start Tailscale: native runtime did not return a usable proxy endpoint.',
      );
    }

    return _NativeStartResult(
      proxyPort: proxyPort,
      proxyAuthToken: proxyAuthToken,
    );
  } finally {
    calloc.free(p1);
    calloc.free(p2);
    calloc.free(p3);
    calloc.free(p4);
  }
}

int _listenNativeRuntime({required int localPort, required int tailnetPort}) {
  final result = _decodeNativeMapResult(
    _callNativeString(() {
      return native.duneListen(localPort, tailnetPort);
    }),
  );

  final error = result['error'] as String?;
  if (error != null) {
    throw TailscaleListenException(error);
  }

  final listenPort = result['listenPort'] as int?;
  if (listenPort == null || listenPort <= 0) {
    throw const TailscaleListenException(
      'Native runtime did not return a usable local listen port.',
    );
  }

  return listenPort;
}

void _downNativeRuntime() {
  native.duneStopWatch();
  native.duneStop();
}

void _logoutNativeRuntime(String stateDir) {
  native.duneStopWatch();

  final dirPtr = stateDir.toNativeUtf8();
  try {
    final result = _decodeNativeMapResult(
      _callNativeString(() {
        return native.duneLogout(dirPtr);
      }),
    );
    final error = result['error'] as String?;
    if (error != null) {
      throw TailscaleLogoutException(error);
    }
  } finally {
    calloc.free(dirPtr);
  }
}
