import 'dart:async';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:http/http.dart' as pkg_http;
import 'package:path/path.dart' as p;
import 'src/errors.dart';
import 'src/ffi_bindings.dart' as native;
import 'src/proxy_client.dart';
import 'src/status.dart';

export 'src/errors.dart';
export 'src/status.dart';

const _ownedStateSubdirectory = 'tailscale';
final Uri _defaultControlUrl = Uri.parse('https://controlplane.tailscale.com');

String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

/// Native log verbosity for the embedded Tailscale runtime.
enum TailscaleLogLevel { silent, error, info }

extension on TailscaleLogLevel {
  int get nativeValue => switch (this) {
    TailscaleLogLevel.silent => 0,
    TailscaleLogLevel.error => 1,
    TailscaleLogLevel.info => 2,
  };
}

/// Singleton embedded Tailscale node for the current Dart process.
///
/// This package runs one node per process. Configure it once with [init], then
/// access the singleton through [instance].
class Tailscale {
  Tailscale._();
  static final Tailscale instance = Tailscale._();

  static String? _stateBaseDir;
  static TailscaleLogLevel? _configuredLogLevel;
  static bool _initialized = false;

  bool _starting = false;
  bool _started = false;
  int _proxyPort = 0;
  String? _proxyAuthToken;
  pkg_http.Client? _http;
  ReceivePort? _receivePort;
  bool _dartApiInitialized = false;
  final StreamController<TailscaleStatus> _statusController =
      StreamController<TailscaleStatus>.broadcast();
  final StreamController<TailscaleRuntimeError> _errorController =
      StreamController<TailscaleRuntimeError>.broadcast();
  TailscaleStatus _lastStatus = TailscaleStatus.stopped;

  static String get _ownedStateDir =>
      p.join(_stateBaseDir!, _ownedStateSubdirectory);

  /// Whether the Tailscale node is currently running.
  bool get isRunning => _started;

  /// An HTTP client that routes requests through the Tailscale tunnel.
  ///
  /// Created lazily on first access. Use like any `http.Client`:
  /// ```dart
  /// await tsnet.httpClient.get(Uri.parse('http://100.64.0.5/api/data'));
  /// ```
  ///
  /// Throws [TailscaleUsageException] if [up] hasn't been called.
  pkg_http.Client get httpClient {
    if (!_started) {
      throw const TailscaleUsageException(
        'Call up() before accessing httpClient.',
      );
    }
    final proxyAuthToken = _proxyAuthToken;
    if (proxyAuthToken == null) {
      throw const TailscaleUsageException('Tailscale proxy is not ready.');
    }
    return _http ??= TailscaleProxyClient(_proxyPort, proxyAuthToken);
  }

  /// The local proxy port used internally by [httpClient].
  ///
  /// This is exposed for diagnostics only. Direct requests through the proxy
  /// are not a stable public API and require an internal per-session token.
  @Deprecated('Use httpClient instead of the internal proxy port.')
  int get proxyPort => _proxyPort;

  /// Real-time status snapshots pushed from the embedded node.
  ///
  /// Each event is a full local-node [TailscaleStatus] snapshot, not a delta
  /// object. Peer inventory is intentionally excluded; call [peers] when you
  /// need a peer snapshot.
  ///
  /// Errors are reported separately through [runtimeErrors].
  Stream<TailscaleStatus> get statusChanges => _statusController.stream;

  /// Background runtime errors pushed from the embedded node.
  ///
  /// These are asynchronous engine/watcher failures, not call-specific
  /// exceptions from [up], [listen], or [status].
  Stream<TailscaleRuntimeError> get runtimeErrors => _errorController.stream;

  /// Configures the Tailscale library. Call this once at app startup,
  /// alongside other library initializers (Firebase, Supabase, etc.).
  ///
  /// [stateDir] is a base directory owned by your app. Tailscale persists its
  /// authentication state in a dedicated `tailscale/` subdirectory inside it.
  ///
  /// [logLevel] controls native log verbosity.
  ///
  /// Repeated calls are allowed only if they use the same effective
  /// configuration. Calling [init] again with a different [stateDir] or
  /// [logLevel] throws [TailscaleUsageException].
  static void init({
    required String stateDir,
    TailscaleLogLevel logLevel = TailscaleLogLevel.silent,
  }) {
    if (stateDir.trim().isEmpty) {
      throw const TailscaleUsageException('stateDir must not be empty.');
    }
    final normalizedStateDir = p.normalize(p.absolute(stateDir));
    if (_initialized) {
      if (_stateBaseDir == normalizedStateDir &&
          _configuredLogLevel == logLevel) {
        return;
      }

      throw TailscaleUsageException(
        'Tailscale.init() has already been called for this process. '
        'Repeated calls must use the same stateDir and logLevel.',
      );
    }

    _stateBaseDir = normalizedStateDir;
    _configuredLogLevel = logLevel;
    _initialized = true;
    native.duneSetLogLevel(logLevel.nativeValue);
  }

  /// Brings the embedded Tailscale node up and connects to the control plane.
  ///
  /// Returns the current [TailscaleStatus] when the node reaches "Running"
  /// (connected and ready to send/receive traffic), or throws
  /// [TailscaleTimeoutException] if it does not reach Running within
  /// [timeout].
  ///
  /// After [up], use [httpClient] to make requests to peers.
  ///
  /// [hostname] controls the node's tailnet-visible hostname / MagicDNS base
  /// label. Leave it unset to let the embedded runtime pick its default.
  ///
  /// On first use, provide [authKey] to register the node. On subsequent
  /// launches, the node reconnects using stored credentials — [authKey]
  /// can be omitted. Subscribe to [statusChanges] to observe auth URLs and
  /// intermediate states while [up] is in progress.
  ///
  /// [controlUrl] selects the control plane. Use the default for Tailscale, or
  /// point it at your Headscale deployment.
  ///
  /// To accept incoming traffic, call [listen] after [up].
  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    Uri? controlUrl,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _ensureInitialized();
    if (_started) {
      throw const TailscaleUsageException(
        'Already up. Call down() before reconnecting.',
      );
    }
    if (_starting) {
      throw const TailscaleUsageException('up() is already in progress.');
    }
    _starting = true;

    final stateDir = _ownedStateDir;
    final resolvedControlUrl = controlUrl ?? _defaultControlUrl;
    var nativeStarted = false;

    try {
      // Boot the Go engine on a background isolate.
      final startResult = await Isolate.run(() {
        final p1 = hostname.toNativeUtf8();
        final p2 = (authKey ?? '').toNativeUtf8();
        final p3 = resolvedControlUrl.toString().toNativeUtf8();
        final p4 = stateDir.toNativeUtf8();

        try {
          final resultPtr = native.duneStart(p1, p2, p3, p4);
          final resultJson = resultPtr.toDartString();
          native.duneFree(resultPtr);

          return Map<String, dynamic>.from(
            jsonDecode(resultJson) as Map<String, dynamic>,
          );
        } finally {
          calloc.free(p1);
          calloc.free(p2);
          calloc.free(p3);
          calloc.free(p4);
        }
      });

      final startError = startResult['error'] as String?;
      if (startError != null) {
        throw TailscaleUpException(startError);
      }
      final proxyPort = startResult['proxyPort'] as int? ?? 0;
      final proxyAuthToken = startResult['proxyAuthToken'] as String?;

      if (proxyPort == 0 || proxyAuthToken == null || proxyAuthToken.isEmpty) {
        throw const TailscaleUpException(
          'Failed to start Tailscale: native runtime did not return a usable proxy endpoint.',
        );
      }

      _proxyPort = proxyPort;
      _proxyAuthToken = proxyAuthToken;
      nativeStarted = true;

      // Set up the push channel and wait for Running state.
      _setupPushChannel();

      await _waitForRunning(timeout);

      _started = true;
      return await _publishCurrentStatus();
    } catch (error, stackTrace) {
      // Clean up on failure.
      _teardownPushChannel();
      _proxyPort = 0;
      _proxyAuthToken = null;
      _http?.close();
      _http = null;
      if (nativeStarted) {
        await Isolate.run(() {
          native.duneStop();
        });
      }
      _publishStatus(TailscaleStatus.stopped);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _starting = false;
    }
  }

  /// Exposes a local HTTP server to peers on the tailnet.
  ///
  /// Tailnet peers can reach this node on [tailnetPort]. Traffic is forwarded
  /// to `localhost:<localPort>`. If [localPort] is 0 (default), an ephemeral
  /// local port is allocated — bind your server to the returned port.
  ///
  /// Can be called multiple times to change the local target port or
  /// tailnet-facing port. This is an HTTP convenience API, not a general
  /// `tsnet.Listen` equivalent.
  ///
  /// Returns the local port that receives incoming traffic.
  Future<int> listen({int localPort = 0, int tailnetPort = 80}) async {
    if (!_started) {
      throw const TailscaleUsageException('Call up() before listen().');
    }

    final result = await Isolate.run(() {
      final resultPtr = native.duneListen(localPort, tailnetPort);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      return Map<String, dynamic>.from(
        jsonDecode(resultJson) as Map<String, dynamic>,
      );
    });

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

  /// Returns the current Tailscale status.
  ///
  /// Includes backend state, local IPs, health, and tailnet info.
  ///
  /// Peer inventory is intentionally excluded so status polling and
  /// [statusChanges] stay lightweight. Call [peers] when you need the current
  /// peer snapshot.
  Future<TailscaleStatus> status() async {
    _ensureInitialized();
    final json = await Isolate.run(() {
      return _callNativeString(native.duneStatus);
    });
    try {
      final parsed = Map<String, dynamic>.from(
        jsonDecode(json) as Map<String, dynamic>,
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

  /// Returns the current peer snapshot for the tailnet.
  ///
  /// This is separated from [status] so apps can watch lightweight node-state
  /// updates without reloading the full peer inventory each time.
  Future<List<PeerStatus>> peers() async {
    _ensureInitialized();
    final json = await Isolate.run(() {
      return _callNativeString(native.dunePeers);
    });
    try {
      final parsed = jsonDecode(json) as List<dynamic>;
      return parsed
          .map((peer) => PeerStatus.fromJson(Map<String, dynamic>.from(peer)))
          .toList(growable: false);
    } catch (error) {
      throw TailscaleStatusException(
        'Failed to decode native Tailscale peers.',
        cause: error,
      );
    }
  }

  /// Brings the embedded node down while preserving persisted state.
  ///
  /// Preserves state in the configured state directory, so the next
  /// [up] call can reconnect without a fresh auth key.
  ///
  /// No-op if not running.
  Future<void> down() async {
    if (_starting) {
      throw const TailscaleUsageException(
        'Cannot call down() while up() is in progress.',
      );
    }
    if (!_started) return;
    _started = false;
    _proxyPort = 0;
    _proxyAuthToken = null;
    _http?.close();
    _http = null;
    _teardownPushChannel();
    await Isolate.run(() {
      native.duneStop();
    });
    _publishStatus(TailscaleStatus.stopped);
  }

  /// Logs out and clears persisted state for the embedded node.
  ///
  /// The next [up] call will require fresh authentication.
  Future<void> logout() async {
    _ensureInitialized();
    if (_starting) {
      throw const TailscaleUsageException(
        'Cannot call logout() while up() is in progress.',
      );
    }

    _started = false;
    _proxyPort = 0;
    _proxyAuthToken = null;
    _http?.close();
    _http = null;
    _teardownPushChannel();

    final stateDir = _ownedStateDir;
    final result = await Isolate.run(() {
      final dirPtr = stateDir.toNativeUtf8();
      try {
        final resultPtr = native.duneLogout(dirPtr);
        final resultJson = resultPtr.toDartString();
        native.duneFree(resultPtr);
        return Map<String, dynamic>.from(
          jsonDecode(resultJson) as Map<String, dynamic>,
        );
      } finally {
        calloc.free(dirPtr);
      }
    });

    final error = result['error'] as String?;
    if (error != null) {
      throw TailscaleLogoutException(error);
    }

    _publishStatus(TailscaleStatus.stopped);
  }

  // ---------------------------------------------------------------------------
  // Push channel (Go → Dart via NativePort)
  // ---------------------------------------------------------------------------

  Completer<void>? _runningCompleter;

  void _setupPushChannel() {
    // Initialize the Dart native API (idempotent — safe to call multiple times
    // but only the first call does anything).
    if (!_dartApiInitialized) {
      final result = native.duneInitDartAPI(ffi.NativeApi.initializeApiDLData);
      if (result != 0) {
        throw const TailscaleUpException(
          'Failed to initialize the Dart native API bridge.',
        );
      }
      _dartApiInitialized = true;
    }

    // Create a receive port for Go to push messages to.
    _receivePort = ReceivePort();
    native.duneSetDartPort(_receivePort!.sendPort.nativePort);

    _receivePort!.listen(_handlePushMessage);

    // Start the Go-side state watcher.
    native.duneStartWatch();
  }

  void _teardownPushChannel() {
    native.duneStopWatch();
    native.duneSetDartPort(0);
    _receivePort?.close();
    _receivePort = null;
  }

  void _handlePushMessage(dynamic message) {
    if (message is! String) return;

    try {
      final parsed = jsonDecode(message) as Map<String, dynamic>;

      if (parsed['type'] == 'error') {
        final error = TailscaleRuntimeError.fromPushPayload(parsed);
        if (_runningCompleter != null && !_runningCompleter!.isCompleted) {
          _runningCompleter!.completeError(TailscaleUpException(error.message));
        }
        _publishRuntimeError(error);
        return;
      }

      if (parsed['type'] == 'status') {
        final state = parsed['state'] as String?;

        // Resolve the Running completer if we're waiting for it.
        if (state == 'Running' &&
            _runningCompleter != null &&
            !_runningCompleter!.isCompleted) {
          _runningCompleter!.complete();
        }

        unawaited(_publishCurrentStatus());
      }
    } catch (_) {
      // Malformed message from Go — ignore.
    }
  }

  Future<void> _waitForRunning(Duration timeout) async {
    _runningCompleter = Completer<void>();

    try {
      await _runningCompleter!.future.timeout(
        timeout,
        onTimeout: () => throw TailscaleTimeoutException(
          message: _buildUpTimeoutMessage(timeout),
          timeout: timeout,
          lastStatus: _lastStatus,
        ),
      );
    } finally {
      _runningCompleter = null;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw const TailscaleUsageException(
        'Tailscale.init() must be called before using the library.',
      );
    }
  }

  Future<TailscaleStatus> _publishCurrentStatus() async {
    try {
      final snapshot = await status();
      _publishStatus(snapshot);
      return snapshot;
    } catch (_) {
      // Ignore best-effort status publication failures.
      return _lastStatus;
    }
  }

  void _publishStatus(TailscaleStatus status) {
    _lastStatus = status;
    _statusController.add(status);
  }

  void _publishRuntimeError(TailscaleRuntimeError error) {
    _errorController.add(error);
  }

  String _buildUpTimeoutMessage(Duration timeout) {
    final lastStatus = _lastStatus;
    if (lastStatus.nodeStatus == NodeStatus.needsLogin) {
      final authUrl = lastStatus.authUrl;
      if (authUrl != null) {
        return 'Tailscale needs login before it can reach Running. Open '
            '$authUrl, finish authentication, then retry up().';
      }
      return 'Tailscale needs login before it can reach Running. Subscribe to '
          'statusChanges to receive the auth URL, then retry up().';
    }
    if (lastStatus.nodeStatus == NodeStatus.needsMachineAuth) {
      return 'Tailscale is waiting for machine approval on the control plane '
          'and did not reach Running within $timeout.';
    }

    return 'Tailscale did not reach Running state within $timeout. Check that '
        'the control server is reachable.';
  }
}
