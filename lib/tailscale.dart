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

  bool _starting = false;
  bool _started = false;
  int _proxyPort = 0;
  _TailscaleHttpClient? _http;

  /// Whether the Tailscale node is currently running.
  bool get isRunning => _started;

  /// An HTTP client that routes requests through the Tailscale tunnel.
  ///
  /// Created lazily on first access. Use like any [pkg_http.Client]:
  /// ```dart
  /// await tsnet.client.get(Uri.parse('http://100.64.0.5/api/data'));
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
  /// should use [client] instead.
  int get proxyPort => _proxyPort;

  /// Creates an HTTP client that routes requests through a proxy on [port].
  ///
  /// Useful for testing or when you need a client for a specific proxy port.
  static pkg_http.Client createProxyClient(int port) => _TailscaleHttpClient(port);

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
  static void init({
    required String stateDir,
    int logLevel = 0,
  }) {
    _stateDir = stateDir;
    _initialized = true;
    native.duneSetLogLevel(logLevel);
  }

  /// Checks if the configured state directory contains a valid machine key
  /// from a previous session.
  ///
  /// Call [init] first. Use this to decide whether to reconnect automatically
  /// or prompt for an auth key.
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
  /// After start, use [client] to make HTTP requests to peers on the tailnet.
  ///
  /// On first use, provide [authKey] and [controlUrl] to register the node.
  /// On subsequent launches, the node reconnects using stored credentials —
  /// these parameters can be omitted. To switch tailnets, delete the
  /// state directory and call [start] with new credentials.
  ///
  /// To accept incoming traffic, call [listen] after start.
  ///
  /// Runs on a background isolate — does not block the calling isolate.
  ///
  /// Throws [StateError] if [init] hasn't been called, if already started,
  /// or if another start is in progress.
  ///
  /// Throws [TimeoutException] if the operation takes longer than [timeout].
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
      }).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Tailscale start timed out after $timeout. '
          'Check that the control server at $controlUrl is reachable.',
          timeout,
        ),
      );

      if (proxyPort == 0) {
        throw Exception('Failed to start Tailscale (proxy port 0)');
      }

      _proxyPort = proxyPort;
      _started = true;
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
  /// If [port] is provided, traffic is forwarded to that port (your server
  /// should already be listening there).
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
    await Isolate.run(() {
      native.duneStop();
    });
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
          'Tailscale.init() must be called before using the library.');
    }
  }
}
