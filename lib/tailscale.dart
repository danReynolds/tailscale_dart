library tailscale_dart;

import 'dart:async';
import 'dart:collection';
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

part 'src/worker/commands.dart';
part 'src/worker/worker.dart';

const _ownedStateSubdirectory = 'tailscale';
final Uri _defaultControlUrl = Uri.parse('https://controlplane.tailscale.com');
const _workerExitedSentinel = '_tailscaleWorkerExited';

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
  ReceivePort? _workerPort;
  Isolate? _workerIsolate;
  SendPort? _workerCommandPort;
  Completer<void>? _workerReadyCompleter;
  // Commands are processed synchronously on the worker isolate and each
  // command produces exactly one response in request order, so a FIFO queue is
  // sufficient for matching RPC responses without request IDs.
  final Queue<Completer<_WorkerResponse>> _pendingWorkerResponses =
      Queue<Completer<_WorkerResponse>>();
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
      final startResult = await _startWorker(
        hostname: hostname,
        authKey: authKey ?? '',
        controlUrl: resolvedControlUrl.toString(),
        stateDir: stateDir,
      );
      _proxyPort = startResult.proxyPort;
      _proxyAuthToken = startResult.proxyAuthToken;
      nativeStarted = true;

      await _waitForRunning(timeout);

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
          await _downWorker();
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

    return _listenWorker(localPort: localPort, tailnetPort: tailnetPort);
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
    return _statusWorker();
  }

  /// Returns the current peer snapshot for the tailnet.
  ///
  /// This is separated from [status] so apps can watch lightweight node-state
  /// updates without reloading the full peer inventory each time.
  Future<List<PeerStatus>> peers() async {
    _ensureInitialized();
    return _peersWorker();
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
    await _downWorker();
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
    await _logoutWorker(stateDir);
    _publishStatus(TailscaleStatus.stopped);
  }

  // ---------------------------------------------------------------------------
  // Native worker isolate
  // ---------------------------------------------------------------------------

  Completer<void>? _runningCompleter;

  Future<void> _ensureWorkerStarted() async {
    if (_workerCommandPort != null) return;
    if (_workerReadyCompleter != null) {
      return _workerReadyCompleter!.future;
    }

    final readyCompleter = Completer<void>();
    _workerReadyCompleter = readyCompleter;

    _workerPort = ReceivePort();
    _workerPort!.listen(_handleWorkerMessage);

    try {
      _workerIsolate = await Isolate.spawn<SendPort>(
        _nativeWorkerMain,
        _workerPort!.sendPort,
      );
      _workerIsolate!.addOnExitListener(
        _workerPort!.sendPort,
        response: _workerExitedSentinel,
      );
      await readyCompleter.future;
    } catch (error, stackTrace) {
      _resetWorkerState();
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (identical(_workerReadyCompleter, readyCompleter)) {
        _workerReadyCompleter = null;
      }
    }
  }

  void _handleWorkerMessage(dynamic message) {
    if (message == _workerExitedSentinel) {
      _handleWorkerExit();
      return;
    }

    switch (message) {
      case _WorkerReadyMessage():
        _workerCommandPort = message.commandPort;
        if (_workerReadyCompleter != null &&
            !_workerReadyCompleter!.isCompleted) {
          _workerReadyCompleter!.complete();
        }
      case _WorkerBootstrapFailureMessage():
        if (_workerReadyCompleter != null &&
            !_workerReadyCompleter!.isCompleted) {
          _workerReadyCompleter!.completeError(
            TailscaleUpException(message.message),
          );
        } else {
          _publishRuntimeError(
            TailscaleRuntimeError(
              message: message.message,
              code: TailscaleRuntimeErrorCode.node,
            ),
          );
        }
      case _WorkerRuntimeErrorEvent():
        final error = message.error;
        if (_runningCompleter != null && !_runningCompleter!.isCompleted) {
          _runningCompleter!.completeError(TailscaleUpException(error.message));
        }
        _publishRuntimeError(error);
      case _WorkerStatusEvent():
        final state = message.state;
        if (state == 'Running' &&
            _runningCompleter != null &&
            !_runningCompleter!.isCompleted) {
          _runningCompleter!.complete();
        }

        final snapshot = message.snapshot;
        if (snapshot != null) {
          _publishStatus(snapshot);
        } else {
          unawaited(_publishCurrentStatus());
        }
      case _WorkerResponse():
        if (_pendingWorkerResponses.isEmpty) {
          _publishRuntimeError(
            const TailscaleRuntimeError(
              message: 'Native worker isolate returned an unexpected response.',
              code: TailscaleRuntimeErrorCode.node,
            ),
          );
          return;
        }

        final completer = _pendingWorkerResponses.removeFirst();
        if (!completer.isCompleted) {
          completer.complete(message);
        }
      default:
        // Ignore unknown messages.
        break;
    }
  }

  void _handleWorkerExit() {
    const error = TailscaleOperationException(
      'worker',
      'Native worker isolate terminated unexpectedly.',
    );

    final readyCompleter = _workerReadyCompleter;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.completeError(error);
    }

    final pending = _pendingWorkerResponses.toList(growable: false);
    _pendingWorkerResponses.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    if (_runningCompleter != null && !_runningCompleter!.isCompleted) {
      _runningCompleter!.completeError(TailscaleUpException(error.message));
    }

    _workerIsolate = null;
    _workerCommandPort = null;
    _workerReadyCompleter = null;
    _workerPort?.close();
    _workerPort = null;
  }

  void _resetWorkerState() {
    const error = TailscaleOperationException(
      'worker',
      'Native worker isolate failed to initialize.',
    );
    final pending = _pendingWorkerResponses.toList(growable: false);
    _pendingWorkerResponses.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _workerCommandPort = null;
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerPort?.close();
    _workerPort = null;
  }

  Future<TResponse> _requestWorker<TResponse extends _WorkerResponse>(
    _WorkerCommand request,
  ) async {
    await _ensureWorkerStarted();

    final commandPort = _workerCommandPort;
    if (commandPort == null) {
      throw const TailscaleOperationException(
        'worker',
        'Native worker isolate is not ready.',
      );
    }

    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    try {
      commandPort.send(request);
      final response = await completer.future;
      if (response is _WorkerFailureResponse) {
        throw switch (response.operation) {
          _WorkerOperation.start => TailscaleUpException(response.message),
          _WorkerOperation.listen => TailscaleListenException(response.message),
          _WorkerOperation.status => TailscaleStatusException(response.message),
          _WorkerOperation.peers => TailscaleStatusException(response.message),
          _WorkerOperation.down => TailscaleOperationException(
            'down',
            response.message,
          ),
          _WorkerOperation.logout => TailscaleLogoutException(response.message),
        };
      }

      return response as TResponse;
    } catch (error) {
      _pendingWorkerResponses.remove(completer);
      rethrow;
    }
  }

  Future<_WorkerStartResponse> _startWorker({
    required String hostname,
    required String authKey,
    required String controlUrl,
    required String stateDir,
  }) {
    return _requestWorker<_WorkerStartResponse>(
      _WorkerStartCommand(
        hostname: hostname,
        authKey: authKey,
        controlUrl: controlUrl,
        stateDir: stateDir,
      ),
    );
  }

  Future<int> _listenWorker({
    required int localPort,
    required int tailnetPort,
  }) async {
    final response = await _requestWorker<_WorkerListenResponse>(
      _WorkerListenCommand(localPort: localPort, tailnetPort: tailnetPort),
    );
    return response.listenPort;
  }

  Future<TailscaleStatus> _statusWorker() async {
    final response = await _requestWorker<_WorkerStatusResponse>(
      const _WorkerStatusCommand(),
    );
    return response.status;
  }

  Future<List<PeerStatus>> _peersWorker() async {
    final response = await _requestWorker<_WorkerPeersResponse>(
      const _WorkerPeersCommand(),
    );
    return response.peers;
  }

  Future<void> _downWorker() async {
    await _requestWorker<_WorkerAckResponse>(const _WorkerDownCommand());
  }

  Future<void> _logoutWorker(String stateDir) async {
    await _requestWorker<_WorkerAckResponse>(
      _WorkerLogoutCommand(stateDir: stateDir),
    );
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

  /// Testing-only helper. Not part of the stable public API.
  ///
  /// Returns true when a pushed worker event leaves the next queued RPC
  /// response slot untouched, and the following response still resolves it.
  bool debugWorkerEventDoesNotConsumePendingResponseForTest() {
    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    try {
      _handleWorkerMessage(
        const _WorkerStatusEvent(
          state: 'Starting',
          snapshot: TailscaleStatus.stopped,
        ),
      );

      if (_pendingWorkerResponses.length != 1 || completer.isCompleted) {
        return false;
      }

      _handleWorkerMessage(const _WorkerAckResponse(_WorkerOperation.down));
      return _pendingWorkerResponses.isEmpty && completer.isCompleted;
    } finally {
      _pendingWorkerResponses.clear();
    }
  }

  /// Testing-only helper. Not part of the stable public API.
  ///
  /// Returns true when a worker exit fails a queued RPC instead of leaving it
  /// hanging.
  Future<bool> debugWorkerExitFailsPendingResponseForTest() async {
    final completer = Completer<_WorkerResponse>();
    _pendingWorkerResponses.addLast(completer);

    _handleWorkerExit();

    try {
      await completer.future;
      return false;
    } catch (error) {
      return error is TailscaleOperationException &&
          error.operation == 'worker';
    } finally {
      _pendingWorkerResponses.clear();
    }
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
