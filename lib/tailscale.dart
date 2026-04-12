import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:http/http.dart' as pkg_http;
import 'src/ffi_bindings.dart' as native;
import 'src/status.dart';

export 'src/status.dart';

String _callNativeString(ffi.Pointer<Utf8> Function() fn) {
  final ptr = fn();
  final result = ptr.toDartString();
  native.duneFree(ptr);
  return result;
}

/// An HTTP client that routes requests through the Tailscale proxy.
class _TailscaleHttpClient extends pkg_http.BaseClient {
  _TailscaleHttpClient(this._proxyPort);
  final int _proxyPort;
  final _inner = pkg_http.Client();

  @override
  Future<pkg_http.StreamedResponse> send(pkg_http.BaseRequest request) {
    final target = '${request.url.host}:${request.url.port}';
    final proxyUri = Uri.parse(
        'http://127.0.0.1:$_proxyPort${request.url.path}?target=$target'
        '${request.url.query.isNotEmpty ? "&${request.url.query}" : ""}');

    final proxied = pkg_http.StreamedRequest(request.method, proxyUri);
    proxied.headers.addAll(request.headers);

    if (request is pkg_http.Request) {
      proxied.contentLength = request.bodyBytes.length;
      proxied.sink.add(request.bodyBytes);
      proxied.sink.close();
    } else if (request is pkg_http.StreamedRequest) {
      request.finalize().listen(
        proxied.sink.add,
        onDone: proxied.sink.close,
        onError: proxied.sink.addError,
      );
    }

    return _inner.send(proxied);
  }

  @override
  void close() => _inner.close();
}

class Tailscale {
  Tailscale._();
  static Tailscale instance = Tailscale._();

  static String? _stateDir;
  static bool _initialized = false;
  static void Function(TailscaleStatus status)? _onStatusChange;
  static void Function(String error)? _onError;

  bool _starting = false;
  bool _started = false;
  int _proxyPort = 0;
  _TailscaleHttpClient? _http;
  ReceivePort? _receivePort;
  bool _dartApiInitialized = false;

  /// Whether the Tailscale node is currently running.
  bool get isRunning => _started;

  /// An HTTP client that routes requests through the Tailscale tunnel.
  ///
  /// Created lazily on first access. Use like any `http.Client`:
  /// ```dart
  /// await tsnet.http.get(Uri.parse('http://100.64.0.5/api/data'));
  /// ```
  ///
  /// Throws [StateError] if [start] hasn't been called.
  pkg_http.Client get http {
    if (!_started) {
      throw StateError('Call start() before accessing http.');
    }
    return _http ??= _TailscaleHttpClient(_proxyPort);
  }

  /// The local proxy port. Exposed for advanced use cases — most callers
  /// should use [http] instead.
  int get proxyPort => _proxyPort;

  /// Creates an HTTP client that routes requests through a proxy on [port].
  ///
  /// Useful for testing or when you need a client for a specific proxy port.
  static pkg_http.Client createProxyClient(int port) =>
      _TailscaleHttpClient(port);

  /// Configures the Tailscale library. Call this once at app startup,
  /// alongside other library initializers (Firebase, Supabase, etc.).
  ///
  /// [stateDir] is the directory where Tailscale persists authentication
  /// state across app sessions.
  ///
  /// [logLevel] controls native log verbosity:
  /// - 0 = silent (default)
  /// - 1 = errors only
  /// - 2 = info + errors (verbose)
  ///
  /// [onStatusChange] fires whenever the Tailscale backend state changes
  /// (e.g. connecting, running, needs login). Pushed from Go — no polling.
  ///
  /// [onError] fires when the Go engine encounters an error.
  static void init({
    required String stateDir,
    int logLevel = 0,
    void Function(TailscaleStatus status)? onStatusChange,
    void Function(String error)? onError,
  }) {
    _stateDir = stateDir;
    _initialized = true;
    _onStatusChange = onStatusChange;
    _onError = onError;
    native.duneSetLogLevel(logLevel);
  }

  /// Checks if the configured state directory contains a valid machine key
  /// from a previous session.
  ///
  /// Call [init] first.
  Future<bool> isProvisioned() {
    _ensureInitialized();
    final dir = _stateDir!;

    return Isolate.run(() {
      if (!Directory(dir).existsSync()) return false;

      final dirPtr = dir.toNativeUtf8();
      final result = native.duneHasState(dirPtr);
      calloc.free(dirPtr);

      return result == 1;
    });
  }

  /// Starts the Tailscale node and connects to the control plane.
  ///
  /// Returns when the node is in the "Running" state (connected and ready
  /// to send/receive traffic), or throws [TimeoutException] if the node
  /// doesn't reach Running within [timeout].
  ///
  /// After start, use [http] to make requests to peers.
  ///
  /// On first use, provide [authKey] to register the node. On subsequent
  /// launches, the node reconnects using stored credentials — [authKey]
  /// can be omitted. To switch tailnets, delete the state directory and
  /// call [start] with new credentials.
  ///
  /// To accept incoming traffic, call [listen] after start.
  Future<void> start({
    String nodeName = '',
    String authKey = '',
    String controlUrl = 'https://controlplane.tailscale.com',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _ensureInitialized();
    if (_started) {
      throw StateError('Already started. Call close() before restarting.');
    }
    if (_starting) {
      throw StateError('start() is already in progress.');
    }
    _starting = true;

    final stateDir = _stateDir!;

    try {
      // Boot the Go engine on a background isolate.
      final proxyPort = await Isolate.run(() {
        final p1 = nodeName.toNativeUtf8();
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
          return parsed['proxyPort'] as int;
        } finally {
          calloc.free(p1);
          calloc.free(p2);
          calloc.free(p3);
          calloc.free(p4);
        }
      });

      if (proxyPort == 0) {
        throw Exception('Failed to start Tailscale (proxy port 0)');
      }

      _proxyPort = proxyPort;

      // Set up the push channel and wait for Running state.
      _setupPushChannel();

      await _waitForRunning(timeout);

      _started = true;
    } catch (e) {
      // Clean up on failure.
      _teardownPushChannel();
      _proxyPort = 0;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// Starts accepting incoming traffic from the tailnet.
  ///
  /// Tailnet peers can reach this node on port 80. Traffic is forwarded to
  /// `localhost:<port>`. If [port] is 0 (default), an ephemeral port is
  /// allocated — bind your server to the returned port.
  ///
  /// Can be called multiple times to change the target port.
  ///
  /// Returns the local port that receives incoming traffic.
  Future<int> listen({int port = 0}) async {
    if (!_started) {
      throw StateError('Call start() before listen().');
    }

    return Isolate.run(() {
      final resultPtr = native.duneListen(port);
      final resultJson = resultPtr.toDartString();
      native.duneFree(resultPtr);

      final Map<String, dynamic> parsed = jsonDecode(resultJson);
      if (parsed.containsKey('error')) {
        throw Exception(parsed['error']);
      }
      return parsed['listenPort'] as int;
    });
  }

  /// Returns the current Tailscale status.
  ///
  /// Includes backend state, local IPs, online peers, health, and more.
  Future<TailscaleStatus> status() async {
    final json = await Isolate.run(() {
      return _callNativeString(native.duneStatus);
    });
    try {
      return TailscaleStatus.fromJson(jsonDecode(json));
    } catch (_) {
      return TailscaleStatus.stopped;
    }
  }

  /// Closes the Tailscale engine.
  ///
  /// Preserves state in the configured state directory, so the next
  /// [start] call can reconnect without a fresh auth key.
  ///
  /// To fully reset (clear stored state), delete the state directory
  /// after closing.
  ///
  /// No-op if not started.
  Future<void> close() async {
    if (!_started) return;
    _started = false;
    _proxyPort = 0;
    _http?.close();
    _http = null;
    _teardownPushChannel();
    await Isolate.run(() {
      native.duneStop();
    });
  }

  // ---------------------------------------------------------------------------
  // Push channel (Go → Dart via NativePort)
  // ---------------------------------------------------------------------------

  Completer<void>? _runningCompleter;

  void _setupPushChannel() {
    // Initialize the Dart native API (idempotent — safe to call multiple times
    // but only the first call does anything).
    if (!_dartApiInitialized) {
      native.duneInitDartAPI(ffi.NativeApi.initializeApiDLData);
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
        final error = parsed['error'] as String? ?? 'Unknown error';
        _onError?.call(error);
        return;
      }

      if (parsed['type'] == 'status') {
        final state = parsed['state'] as String?;

        // Resolve the Running completer if we're waiting for it.
        if (state == 'Running' && _runningCompleter != null && !_runningCompleter!.isCompleted) {
          _runningCompleter!.complete();
        }

        // Fire the onStatusChange callback with a full status snapshot.
        if (_onStatusChange != null) {
          status().then((s) => _onStatusChange?.call(s));
        }
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
        onTimeout: () => throw TimeoutException(
          'Tailscale did not reach Running state within $timeout. '
          'Check that the control server is reachable.',
          timeout,
        ),
      );
    } finally {
      _runningCompleter = null;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
          'Tailscale.init() must be called before using the library.');
    }
  }
}
