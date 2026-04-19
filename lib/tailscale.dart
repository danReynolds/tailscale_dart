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

  static String? _stateBaseDir;

  pkg_http.Client? _http;

  late final _worker = Worker(
    publishState: _stateController.add,
    publishRuntimeError: _errorController.add,
  );

  // Singleton broadcast controllers — live for the process lifetime alongside
  // the embedded Tailscale engine; intentionally never closed.
  // ignore: close_sinks
  final StreamController<NodeState> _stateController =
      StreamController<NodeState>.broadcast();
  // ignore: close_sinks
  final StreamController<TailscaleRuntimeError> _errorController =
      StreamController<TailscaleRuntimeError>.broadcast();

  static String get _stateDir =>
      p.join(_stateBaseDir!, _ownedStateSubdirectory);

  void _reset() {
    _http?.close();
    _http = null;
  }

  /// An HTTP client that routes requests through the Tailscale tunnel.
  ///
  /// Available after [up] completes. Use like any `http.Client`:
  /// ```dart
  /// await tsnet.http.get(Uri.parse('http://100.64.0.5/api/data'));
  /// ```
  ///
  /// Throws [TailscaleUsageException] if [up] has not been called.
  pkg_http.Client get http {
    if (_http case pkg_http.Client http) {
      return http;
    }
    throw const TailscaleUsageException('Call up() before accessing http.');
  }

  /// Emits the new [NodeState] whenever the node's lifecycle state changes.
  ///
  /// Consecutive duplicates are filtered via `Stream.distinct`: a no-op
  /// [up] (srv already running) reattaches the IPN bus watcher with
  /// `NotifyInitialState`, which re-emits the current state; similarly,
  /// a redundant [logout] would post `NoState` a second time. Subscribers
  /// only see events for actual transitions.
  ///
  /// Use [status] to fetch the full [TailscaleStatus] snapshot (IPs, health,
  /// etc.) when needed.
  ///
  /// Errors are reported separately through [onError].
  Stream<NodeState> get onStateChange => _stateController.stream.distinct();

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
  static void init({
    required String stateDir,
    TailscaleLogLevel logLevel = TailscaleLogLevel.silent,
  }) {
    if (stateDir.trim().isEmpty) {
      throw const TailscaleUsageException('stateDir must not be empty.');
    }
    final normalizedStateDir = p.normalize(p.absolute(stateDir));

    _stateBaseDir = normalizedStateDir;
    native.duneSetLogLevel(logLevel.nativeValue);
  }

  /// Brings the embedded Tailscale node up and connects to the control plane.
  ///
  /// After [up] returns, the engine is running and [http] is available.
  /// Subscribe to [onStateChange] to observe the node reaching
  /// [NodeState.running].
  ///
  /// **State transitions** (delivered via [onStateChange]):
  ///
  /// - First launch with auth key:
  ///   `noState` → `starting` → `running`
  /// - Subsequent launches with persisted credentials:
  ///   `stopped` → `starting` → `running`
  /// - If credentials have expired:
  ///   `stopped` → `starting` → `needsLogin`
  ///
  /// **No-op** if the node is already running.
  ///
  /// [hostname] controls the node's tailnet-visible hostname / MagicDNS base
  /// label. Leave it unset to let the embedded runtime pick its default.
  ///
  /// [authKey] is required on first use to register the node. On subsequent
  /// launches, omit it to reconnect using stored credentials. If provided on
  /// an already-running node, the engine restarts with the new key.
  ///
  /// Throws [TailscaleUpException] if no [authKey] is provided and no
  /// existing session state is found.
  ///
  /// [controlUrl] selects the control plane. Use the default for Tailscale, or
  /// point it at your Headscale deployment.
  ///
  /// To accept incoming traffic, call [listen] after [up].
  Future<void> up({
    String hostname = '',
    String? authKey,
    Uri? controlUrl,
  }) async {
    final resolvedControlUrl = controlUrl ?? _defaultControlUrl;

    final (:proxyPort, :proxyAuthToken) = await _worker.start(
      hostname: hostname,
      authKey: authKey ?? '',
      controlUrl: resolvedControlUrl.toString(),
      stateDir: _stateDir,
    );
    _http = TailscaleProxyClient(proxyPort, proxyAuthToken);
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
  Future<int> listen(int localPort, {int tailnetPort = 80}) async {
    return _worker.listen(localPort: localPort, tailnetPort: tailnetPort);
  }

  /// Returns the current Tailscale status snapshot.
  ///
  /// Includes the node's [NodeState], assigned IPs, health warnings, and
  /// tailnet metadata. Peer inventory is excluded — call [peers] separately.
  ///
  /// Before [up] is called, the returned [TailscaleStatus.state] reflects
  /// whether persisted credentials exist:
  /// - [NodeState.stopped] — credentials found, ready to reconnect
  /// - [NodeState.noState] — no credentials, an auth key is required
  Future<TailscaleStatus> status() async {
    return _worker.status(stateDir: _stateDir);
  }

  /// Returns the current peer snapshot for the tailnet.
  ///
  /// This is separated from [status] so apps can watch lightweight node-state
  /// updates without reloading the full peer inventory each time.
  Future<List<PeerStatus>> peers() async {
    return _worker.peers();
  }

  /// Brings the embedded node down while preserving persisted credentials.
  ///
  /// After [down], [status] returns [NodeState.stopped] and the next
  /// [up] call can reconnect without an auth key.
  ///
  /// No-op if not running.
  Future<void> down() async {
    _reset();
    await _worker.down();
  }

  /// Logs out and clears persisted credentials for the embedded node.
  ///
  /// After [logout], [status] returns [NodeState.noState] and the next
  /// [up] call will require a fresh auth key.
  Future<void> logout() async {
    _reset();
    await _worker.logout(_stateDir);
  }
}
