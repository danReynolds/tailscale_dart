library tailscale_dart;

import 'dart:async';
import 'package:http/http.dart' as pkg_http;
import 'package:path/path.dart' as p;
import 'src/errors.dart';
import 'src/ffi_bindings.dart' as native;
import 'src/proxy_client.dart';
import 'src/status.dart';
import 'src/worker/worker.dart';

export 'src/errors.dart';
export 'src/status.dart';

const _ownedStateSubdirectory = 'tailscale';
final Uri _defaultControlUrl = Uri.parse('https://controlplane.tailscale.com');

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
  static Tailscale instance = Tailscale._();

  /// Protected constructor for test subclasses.
  @pragma('vm:entry-point')
  Tailscale.forTest();

  static String? _stateBaseDir;
  static TailscaleLogLevel? _configuredLogLevel;
  static bool _initialized = false;

  bool _starting = false;
  bool _started = false;
  int _proxyPort = 0;
  String? _proxyAuthToken;
  pkg_http.Client? _http;

  late final _worker = Worker(
    publishStatus: _publishStatus,
    publishRuntimeError: _publishRuntimeError,
    publishCurrentStatus: _publishCurrentStatus,
  );

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
  /// await tsnet.http.get(Uri.parse('http://100.64.0.5/api/data'));
  /// ```
  ///
  /// Throws [TailscaleUsageException] if [up] has not been called.
  pkg_http.Client get http {
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

  /// Real-time status snapshots pushed from the embedded node.
  ///
  /// Each event is a full local-node [TailscaleStatus] snapshot, not a delta
  /// object. Peer inventory is intentionally excluded; call [peers] when you
  /// need a peer snapshot.
  ///
  /// Errors are reported separately through [onError].
  Stream<TailscaleStatus> get onStatusChange => _statusController.stream;

  /// Background runtime errors pushed from the embedded node.
  ///
  /// These are asynchronous engine/watcher failures, not call-specific
  /// exceptions from [up], [listen], or [status].
  Stream<TailscaleRuntimeError> get onError => _errorController.stream;

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
  /// After [up], use [http] to make requests to peers.
  ///
  /// [hostname] controls the node's tailnet-visible hostname / MagicDNS base
  /// label. Leave it unset to let the embedded runtime pick its default.
  ///
  /// On first use, provide [authKey] to register the node. On subsequent
  /// launches, the node reconnects using stored credentials — [authKey]
  /// can be omitted. Subscribe to [onStatusChange] to observe auth URLs and
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
      final startResult = await _worker.start(
        hostname: hostname,
        authKey: authKey ?? '',
        controlUrl: resolvedControlUrl.toString(),
        stateDir: stateDir,
      );
      _proxyPort = startResult.proxyPort;
      _proxyAuthToken = startResult.proxyAuthToken;
      nativeStarted = true;

      await _worker.waitForRunning(
        timeout,
        onTimeout: () => TailscaleTimeoutException(
          message: _buildUpTimeoutMessage(timeout),
          timeout: timeout,
          lastStatus: _lastStatus,
        ),
      );

      _started = true;
      return await _publishCurrentStatus();
    } catch (error, stackTrace) {
      // Clean up on failure.
      _proxyPort = 0;
      _proxyAuthToken = null;
      _http?.close();
      _http = null;
      if (nativeStarted) {
        try {
          await _worker.down();
        } catch (_) {
          // Best-effort cleanup while surfacing the original startup failure.
        }
      }
      _publishStatus(TailscaleStatus.stopped);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _starting = false;
    }
  }

  /// Exposes a local HTTP server to peers on the tailnet.
  ///
  /// Forwards traffic on the Tailnet to `localhost:<port>`.
  ///
  /// Can be called multiple times to change the local target port or
  /// tailnet-facing port. This is an HTTP convenience API, not a general
  /// `tsnet.Listen` equivalent.
  ///
  /// Returns the local port that receives incoming traffic.
  Future<int> listen(int localPort, {int tailnetPort = 0}) async {
    if (!_started) {
      throw const TailscaleUsageException('Call up() before listen().');
    }

    return _worker.listen(localPort: localPort, tailnetPort: tailnetPort);
  }

  /// Returns the current Tailscale status.
  ///
  /// Includes backend state, local IPs, health, and tailnet info.
  ///
  /// Peer inventory is intentionally excluded so status polling and
  /// [onStatusChange] stay lightweight. Call [peers] when you need the current
  /// peer snapshot.
  Future<TailscaleStatus> status() async {
    _ensureInitialized();
    return _worker.status();
  }

  /// Returns the current peer snapshot for the tailnet.
  ///
  /// This is separated from [status] so apps can watch lightweight node-state
  /// updates without reloading the full peer inventory each time.
  Future<List<PeerStatus>> peers() async {
    _ensureInitialized();
    return _worker.peers();
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
    await _worker.down();
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

    final stateDir = _ownedStateDir;
    await _worker.logout(stateDir);
    _publishStatus(TailscaleStatus.stopped);
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

  /// Testing-only helper. Not part of the stable public API.
  ///
  /// Returns true when a pushed worker event leaves the next queued RPC
  /// response slot untouched, and the following response still resolves it.
  bool debugWorkerEventDoesNotConsumePendingResponseForTest() {
    return _worker.debugEventDoesNotConsumePendingResponse();
  }

  /// Testing-only helper. Not part of the stable public API.
  ///
  /// Returns true when a worker exit fails a queued RPC instead of leaving it
  /// hanging.
  Future<bool> debugWorkerExitFailsPendingResponseForTest() async {
    return _worker.debugExitFailsPendingResponse();
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
          'onStatusChange to receive the auth URL, then retry up().';
    }
    if (lastStatus.nodeStatus == NodeStatus.needsMachineAuth) {
      return 'Tailscale is waiting for machine approval on the control plane '
          'and did not reach Running within $timeout.';
    }

    return 'Tailscale did not reach Running state within $timeout. Check that '
        'the control server is reachable.';
  }
}
