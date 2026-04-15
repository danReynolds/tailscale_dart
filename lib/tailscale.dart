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

  static String? _stateBaseDir;

  pkg_http.Client? _http;

  late final _worker = Worker(
    publishStatus: _statusController.add,
    publishRuntimeError: _errorController.add,
  );

  final StreamController<TailscaleStatus> _statusController =
      StreamController<TailscaleStatus>.broadcast();
  final StreamController<TailscaleRuntimeError> _errorController =
      StreamController<TailscaleRuntimeError>.broadcast();

  static String get _stateDir =>
      p.join(_stateBaseDir!, _ownedStateSubdirectory);

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
  /// After [up], use [http] to make requests to peers. Subscribe to
  /// [onStatusChange] to observe the node reaching Running, auth URLs,
  /// and other state transitions.
  ///
  /// [hostname] controls the node's tailnet-visible hostname / MagicDNS base
  /// label. Leave it unset to let the embedded runtime pick its default.
  ///
  /// On first use, provide [authKey] to register the node. On subsequent
  /// launches, the node reconnects using stored credentials.
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
    final stateDir = _stateDir;
    final resolvedControlUrl = controlUrl ?? _defaultControlUrl;

    final (:proxyPort, :proxyAuthToken) = await _worker.start(
      hostname: hostname,
      authKey: authKey ?? '',
      controlUrl: resolvedControlUrl.toString(),
      stateDir: stateDir,
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

  /// Returns the current Tailscale status.
  ///
  /// Includes backend state, local IPs, health, and tailnet info.
  ///
  /// Peer inventory is intentionally excluded so status polling and
  /// [onStatusChange] stay lightweight. Call [peers] when you need the current
  /// peer snapshot.
  Future<TailscaleStatus> status() async {
    return _worker.status();
  }

  /// Returns the current peer snapshot for the tailnet.
  ///
  /// This is separated from [status] so apps can watch lightweight node-state
  /// updates without reloading the full peer inventory each time.
  Future<List<PeerStatus>> peers() async {
    return _worker.peers();
  }

  /// Brings the embedded node down while preserving persisted state.
  ///
  /// Preserves state in the configured state directory, so the next
  /// [up] call can reconnect without a fresh auth key.
  ///
  /// No-op if not running.
  Future<void> down() async {
    await _worker.down();
  }

  /// Logs out and clears persisted state for the embedded node.
  ///
  /// The next [up] call will require fresh authentication.
  Future<void> logout() async {
    _http?.close();
    _http = null;
    await _worker.logout(_stateDir);
  }
}
