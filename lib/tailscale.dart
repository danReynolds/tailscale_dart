import 'dart:async';
import 'package:http/http.dart' as pkg_http;
import 'package:path/path.dart' as p;
import 'src/api/diag.dart';
import 'src/api/exit_node.dart';
import 'src/api/funnel.dart';
import 'src/api/http.dart';
import 'src/api/identity.dart';
import 'src/api/prefs.dart';
import 'src/api/profiles.dart';
import 'src/api/serve.dart';
import 'src/api/taildrop.dart';
import 'src/api/tcp.dart';
import 'src/api/tls.dart';
import 'src/api/udp.dart';
import 'src/errors.dart';
import 'src/ffi_bindings.dart' as native;
import 'src/proxy_client.dart';
import 'src/status.dart';
import 'src/worker/worker.dart';

export 'src/api/diag.dart';
export 'src/api/exit_node.dart';
export 'src/api/funnel.dart';
export 'src/api/http.dart';
export 'src/api/identity.dart';
export 'src/api/prefs.dart';
export 'src/api/profiles.dart';
export 'src/api/serve.dart';
export 'src/api/taildrop.dart';
export 'src/api/tcp.dart';
export 'src/api/tls.dart';
export 'src/api/udp.dart';
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
/// This package runs one node per process. Configure it once with [init],
/// then access the singleton through [instance].
///
/// ## Shape
///
/// - **Lifecycle** (top-level): [up], [down], [logout], [status], [peers],
///   [onStateChange], [onPeersChange], [onError].
/// - **Transport primitives** (namespaced, return `dart:io` types): [tcp],
///   [tls], [udp], [funnel], [http].
/// - **Feature namespaces**: [taildrop], [serve], [exitNode], [profiles],
///   [prefs].
/// - **Diagnostics**: [diag].
/// - **Identity**: [whois].
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

  // ─── Transport namespaces ───────────────────────────────────────────
  final Tcp    tcp    = const Tcp();
  final Tls    tls    = const Tls();
  final Udp    udp    = const Udp();
  final Funnel funnel = const Funnel();
  late final Http http = Http.internal(
    clientGetter: () => _http,
    exposeFn: (localPort, tailnetPort) =>
        _worker.listen(localPort: localPort, tailnetPort: tailnetPort),
  );

  // ─── Feature namespaces ─────────────────────────────────────────────
  final Taildrop taildrop = const Taildrop();
  final Serve    serve    = const Serve();
  final ExitNode exitNode = const ExitNode();
  final Profiles profiles = const Profiles();
  final Prefs    prefs    = const Prefs();

  // ─── Diagnostics ────────────────────────────────────────────────────
  final Diag diag = const Diag();

  // ─── Streams ────────────────────────────────────────────────────────

  /// Emits the new [NodeState] whenever the node's lifecycle state changes.
  ///
  /// Consecutive duplicates are filtered via `Stream.distinct`: a no-op
  /// [up] (srv already running) reattaches the IPN bus watcher with
  /// `NotifyInitialState`, which re-emits the current state; similarly,
  /// a redundant [logout] would post `NoState` a second time. Subscribers
  /// only see events for actual transitions.
  Stream<NodeState> get onStateChange => _stateController.stream.distinct();

  /// Emits the full peer list on any change (node joined, left, went
  /// on/off-line, tags or DNS name changed).
  ///
  /// Saves callers from polling [peers] on a timer. Derived from the
  /// same IPN bus as [onStateChange].
  Stream<List<PeerStatus>> get onPeersChange =>
      throw UnimplementedError('onPeersChange not yet implemented');

  /// Background runtime errors pushed from the embedded node.
  Stream<TailscaleRuntimeError> get onError => _errorController.stream;

  // ─── Lifecycle ──────────────────────────────────────────────────────

  /// Configures the Tailscale library. Call this once at app startup,
  /// alongside other library initializers.
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
  /// State transitions delivered via [onStateChange]:
  /// - First launch: `noState → starting → running`
  /// - Reconnect with persisted creds: `stopped → starting → running`
  /// - If creds are expired: `stopped → starting → needsLogin` (with
  ///   [TailscaleStatus.authUrl] populated)
  ///
  /// No-op if already running (without a new authKey).
  ///
  /// Throws [TailscaleUpException] if no [authKey] is provided and no
  /// persisted session state exists.
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

  /// Returns the current status snapshot.
  Future<TailscaleStatus> status() async =>
      _worker.status(stateDir: _stateDir);

  /// Returns the current peer snapshot.
  Future<List<PeerStatus>> peers() async => _worker.peers();

  /// Resolves a tailnet IP to the peer's identity (owner, hostname, tags).
  ///
  /// Useful for authorization decisions on incoming connections —
  /// combine with [tcp] `.bind(...)` and check tags before handling
  /// the connection.
  Future<PeerIdentity> whois(String ip) =>
      throw UnimplementedError('whois not yet implemented');

  /// Brings the embedded node down while preserving persisted credentials.
  Future<void> down() async {
    _reset();
    await _worker.down();
  }

  /// Logs out and clears persisted credentials.
  Future<void> logout() async {
    _reset();
    await _worker.logout(_stateDir);
  }
}
