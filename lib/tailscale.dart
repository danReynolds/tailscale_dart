import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:meta/meta.dart' show visibleForTesting;

import 'src/ffi_bindings.dart' as native;
import 'src/status.dart';

export 'src/status.dart';

/// Calls a native function that returns a C string, converts to Dart string,
/// and frees the native pointer.
String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

class DuneTsnet {
  DuneTsnet._();
  static DuneTsnet instance = DuneTsnet._();

  int _proxyPort = 0;
  bool _initializing = false;
  bool _initialized = false;

  final _statusController = StreamController<TailscaleStatus>.broadcast();
  Timer? _statusPoller;
  TailscaleStatus? _lastStatus;

  @visibleForTesting
  set proxyPortForTesting(int port) => _proxyPort = port;

  /// The local proxy port (0 if not started).
  int get proxyPort => _proxyPort;

  /// Whether the Tailscale node is currently running.
  bool get isRunning => _initialized && _proxyPort > 0;

  /// A broadcast stream of [TailscaleStatus] updates.
  ///
  /// Emits whenever the backend state, peer list, or local IP changes.
  /// Starts polling when [init] succeeds, stops on [stop] or [logout].
  Stream<TailscaleStatus> get statusStream => _statusController.stream;

  /// Sets the native logging level.
  ///
  /// - 0 = silent (default)
  /// - 1 = errors only
  /// - 2 = info + errors (verbose)
  ///
  /// Can be called at any time, including before [init].
  static void setLogLevel(int level) {
    native.duneSetLogLevel(level);
  }

  /// Initializes the Tailscale node and starts the local HTTP proxy.
  ///
  /// Runs on a background isolate — does not block the calling isolate.
  ///
  /// Throws [StateError] if already initialized or if another init is in progress.
  /// Call [stop] or [logout] first to re-initialize.
  ///
  /// Throws [TimeoutException] if the operation takes longer than [timeout].
  ///
  /// [stateDir] is the directory where Tailscale persists authentication state.
  /// The caller provides this (Flutter apps use path_provider, CLI apps use any path).
  Future<void> init({
    required String clientId,
    required String authKey,
    required String controlUrl,
    required String stateDir,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_initialized) {
      throw StateError(
          'Already initialized. Call stop() or logout() before re-initializing.');
    }
    if (_initializing) {
      throw StateError('init() is already in progress.');
    }
    _initializing = true;

    try {
      final port = await Isolate.run(() {
        final p1 = clientId.toNativeUtf8();
        final p2 = authKey.toNativeUtf8();
        final p3 = controlUrl.toNativeUtf8();
        final p4 = stateDir.toNativeUtf8();

        try {
          final resultPtr = native.duneStart(p1, p2, p3, p4);
          final resultJson = resultPtr.toDartString();
          native.duneFree(resultPtr);

          final Map<String, dynamic> parsed = jsonDecode(resultJson);
          if (parsed.containsKey('error')) {
            throw Exception(parsed['error']);
          }
          return parsed['port'] as int;
        } finally {
          calloc.free(p1);
          calloc.free(p2);
          calloc.free(p3);
          calloc.free(p4);
        }
      }).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Tailscale init timed out after $timeout. '
          'Check that the control server at $controlUrl is reachable.',
          timeout,
        ),
      );

      _proxyPort = port;
      if (_proxyPort == 0) {
        throw Exception('Failed to start Tsnet (port 0)');
      }
      _initialized = true;
      _startStatusPoller();
    } finally {
      _initializing = false;
    }
  }

  /// Starts the reverse proxy that listens on the Tailscale network (port 80)
  /// and forwards traffic to [localPort].
  ///
  /// Runs on a background isolate.
  Future<void> startReverseProxy(int localPort) async {
    await Isolate.run(() {
      native.duneListen(localPort);
    });
  }

  /// Returns the proxy URI to reach a Tailscale peer.
  ///
  /// Pure Dart — safe to call from the main isolate.
  Uri getProxyUri(String targetIp, String path, {int targetPort = 80}) {
    if (_proxyPort == 0) throw Exception('Not running');
    return Uri.parse(
        'http://127.0.0.1:$_proxyPort$path?target=$targetIp:$targetPort');
  }

  /// Returns the list of online peer IPv4 addresses.
  ///
  /// Runs on a background isolate.
  Future<List<String>> getPeerAddresses() async {
    return Isolate.run(() {
      final jsonStr = _callNativeString(native.duneGetPeers);
      try {
        final List<dynamic> list = jsonDecode(jsonStr);
        return list.cast<String>();
      } catch (_) {
        return <String>[];
      }
    });
  }

  /// Returns the local Tailscale IPv4 address, or null if unavailable.
  ///
  /// Runs on a background isolate.
  Future<String?> getLocalIP() async {
    return Isolate.run(() {
      final ip = _callNativeString(native.duneGetLocalIP);
      return ip.isNotEmpty ? ip : null;
    });
  }

  /// Checks if the node has previously authenticated (has a valid machine key).
  ///
  /// Runs on a background isolate (opens and queries SQLite).
  Future<bool> isProvisioned(String stateDir) async {
    return Isolate.run(() {
      if (!Directory(stateDir).existsSync()) return false;

      final dirPtr = stateDir.toNativeUtf8();
      final result = native.duneHasState(dirPtr);
      calloc.free(dirPtr);

      return result == 1;
    });
  }

  /// Clears authentication state and stops the server.
  ///
  /// No-op if not initialized. Runs on a background isolate.
  Future<void> logout(String stateDir) async {
    if (!_initialized) return;
    _stopStatusPoller();
    _initialized = false;
    _proxyPort = 0;
    await Isolate.run(() {
      final dirPtr = stateDir.toNativeUtf8();
      native.duneLogout(dirPtr);
      calloc.free(dirPtr);
    });
    _emitStatus(TailscaleStatus.stopped);
  }

  /// Stops the Tailscale engine (preserves state for reconnection).
  ///
  /// No-op if not initialized. Runs on a background isolate.
  Future<void> stop() async {
    if (!_initialized) return;
    _stopStatusPoller();
    _initialized = false;
    _proxyPort = 0;
    await Isolate.run(() {
      native.duneStop();
    });
    _emitStatus(TailscaleStatus.stopped);
  }

  /// Returns the full Tailscale status as a raw JSON string.
  ///
  /// Prefer [getTypedStatus] for typed access.
  /// Runs on a background isolate.
  Future<String> getStatus() async {
    return Isolate.run(() {
      return _callNativeString(native.duneStatus);
    });
  }

  /// Returns the current Tailscale status as a typed [TailscaleStatus].
  ///
  /// Runs on a background isolate.
  Future<TailscaleStatus> getTypedStatus() async {
    final json = await getStatus();
    try {
      return TailscaleStatus.fromJson(jsonDecode(json));
    } catch (_) {
      return TailscaleStatus.stopped;
    }
  }

  // ---------------------------------------------------------------------------
  // Status polling
  // ---------------------------------------------------------------------------

  void _startStatusPoller() {
    _statusPoller?.cancel();
    _statusPoller = Timer.periodic(const Duration(seconds: 2), (_) async {
      // Don't poll if the engine has been stopped since the timer fired.
      if (!_initialized) return;
      try {
        final status = await getTypedStatus();
        if (!_initialized) return; // Check again after async gap.
        if (_lastStatus == null || !status.sameAs(_lastStatus!)) {
          _emitStatus(status);
        }
      } catch (_) {
        // Ignore errors during polling — engine may be shutting down.
      }
    });
  }

  void _stopStatusPoller() {
    _statusPoller?.cancel();
    _statusPoller = null;
    _lastStatus = null;
  }

  void _emitStatus(TailscaleStatus status) {
    _lastStatus = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}
