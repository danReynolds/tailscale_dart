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

export 'src/api/diag.dart'
    hide createDiag, DiagPingFn, DiagMetricsFn, DiagDERPMapFn, DiagCheckUpdateFn;
export 'src/api/exit_node.dart';
export 'src/api/funnel.dart' hide attachFunnelMetadata;
export 'src/api/http.dart' hide createHttp;
export 'src/api/identity.dart';
export 'src/api/prefs.dart';
export 'src/api/profiles.dart';
export 'src/api/serve.dart';
export 'src/api/taildrop.dart';
export 'src/api/tcp.dart' hide createTcp, TcpDialFn, TcpBindFn, TcpUnbindFn;
export 'src/api/tls.dart' hide createTls, TlsDomainsFn;
export 'src/api/udp.dart';
export 'src/errors.dart';
export 'src/status.dart';

const _ownedStateSubdirectory = 'tailscale';
final Uri _defaultControlUrl = Uri.parse('https://controlplane.tailscale.com');

/// Native log verbosity for the embedded Tailscale runtime — controls
/// what the Go side writes to stderr. Dart-side logging (e.g.
/// [TailscaleRuntimeError]) is unaffected.
enum TailscaleLogLevel {
  /// No native logs at all.
  silent,

  /// Only error-level log lines.
  error,

  /// Informational + error logs. Useful during development; noisy in
  /// production.
  info,
}

extension on TailscaleLogLevel {
  int get nativeValue => switch (this) {
        TailscaleLogLevel.silent => 0,
        TailscaleLogLevel.error => 1,
        TailscaleLogLevel.info => 2,
      };
}

/// Singleton embedded Tailscale node for the current Dart process.
/// Wraps Tailscale's [tsnet](https://tailscale.com/kb/1244/tsnet)
/// userspace library — the Dart app itself becomes a node on the
/// tailnet, no OS-level VPN required.
///
/// This package runs one node per process. Configure it once with
/// [init], then access the singleton through [instance].
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
  late final Tcp tcp = createTcp(
    dialFn: (host, port, timeout) =>
        _worker.tcpDial(host: host, port: port, timeout: timeout),
    bindFn: (tailnetPort, tailnetHost, loopbackPort) => _worker.tcpBind(
      tailnetPort: tailnetPort,
      tailnetHost: tailnetHost,
      loopbackPort: loopbackPort,
    ),
    unbindFn: (loopbackPort) => _worker.tcpUnbind(loopbackPort: loopbackPort),
  );
  late final Tls tls = createTls(domainsFn: _worker.tlsDomains);
  final Udp udp = Udp.instance;
  final Funnel funnel = Funnel.instance;
  late final Http http = createHttp(
    clientGetter: () => _http,
    exposeFn: (localPort, tailnetPort) =>
        _worker.listen(localPort: localPort, tailnetPort: tailnetPort),
  );

  // ─── Feature namespaces ─────────────────────────────────────────────
  final Taildrop taildrop = Taildrop.instance;
  final Serve serve = Serve.instance;
  final ExitNode exitNode = ExitNode.instance;
  final Profiles profiles = Profiles.instance;
  final Prefs prefs = Prefs.instance;

  // ─── Diagnostics ────────────────────────────────────────────────────
  late final Diag diag = createDiag(
    pingFn: (ip, timeout, type) => _worker.diagPing(
      ip: ip,
      timeout: timeout,
      pingType: type.name,
    ),
    metricsFn: _worker.diagMetrics,
    derpMapFn: _worker.diagDERPMap,
    checkUpdateFn: _worker.diagCheckUpdate,
  );

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
  ///
  /// [stateDir] is an app-owned directory where Tailscale persists
  /// its node identity, keys, and profile data under a `tailscale/`
  /// subdirectory. Pick somewhere durable — on Flutter, the
  /// `application_documents_directory` is a good default. On a fresh
  /// install this directory is empty; after the first successful
  /// [up], it contains credentials that let subsequent launches
  /// reconnect without an auth key.
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

  /// Brings the embedded Tailscale node up and connects to the control
  /// plane — Tailscale's coordination service at
  /// `controlplane.tailscale.com`, or a self-hosted
  /// [Headscale](https://github.com/juanfont/headscale) if you set
  /// [controlUrl]. Registers the node on first launch, reconnects from
  /// persisted credentials on subsequent launches.
  ///
  /// [authKey] is required for first registration; get one from the
  /// tailnet admin panel at
  /// <https://login.tailscale.com/admin/settings/keys> (see
  /// <https://tailscale.com/kb/1085/auth-keys>). Reusable keys let you
  /// call [up] from multiple processes; ephemeral keys auto-expire
  /// after the node goes offline. Subsequent launches can omit it —
  /// the persisted session state reconnects automatically.
  ///
  /// [hostname] sets the tailnet-visible hostname and the
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) label, so the
  /// node becomes reachable at `<hostname>.<tailnet>.ts.net`. Leave
  /// unset to let the embedded runtime pick the OS default.
  ///
  /// Resolves on the first **stable** state: `running`, `needsLogin`,
  /// or `needsMachineAuth`. This intentionally differs from Go's
  /// `tsnet.Server.Up`, which blocks only on `running` — a Dart app
  /// that needs to drive an in-app auth flow should not have to
  /// re-enter [up] just to see the [TailscaleStatus.authUrl]. Inspect
  /// the returned [TailscaleStatus.state] to decide what to do next:
  ///
  /// - `running` — ready; [http], [tcp], etc. are usable.
  /// - `needsLogin` — open [TailscaleStatus.authUrl] in a browser /
  ///   web view; the node finishes connecting after the user completes
  ///   the flow.
  /// - `needsMachineAuth` — authenticated but awaiting admin approval
  ///   on the control plane (
  ///   [device approval](https://tailscale.com/kb/1099/device-approval)).
  ///
  /// Transitions delivered via [onStateChange]:
  /// - First launch: `noState → starting → running`
  /// - Reconnect with persisted creds: `stopped → starting → running`
  /// - If creds are expired: `stopped → starting → needsLogin` (with
  ///   [TailscaleStatus.authUrl] populated)
  ///
  /// No-op if already running (without a new authKey).
  ///
  /// Throws [TailscaleUpException] if no [authKey] is provided and no
  /// persisted session state exists, or if the node fails to reach a
  /// stable state within 30 seconds (e.g. control plane unreachable).
  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    Uri? controlUrl,
  }) async {
    final resolvedControlUrl = controlUrl ?? _defaultControlUrl;

    // Only count stable states that arrive AFTER start() returns. If up()
    // is called on an already-running node (with a new authKey), the old
    // engine's lingering `running` emission would otherwise satisfy the
    // "first stable state" check before the restart completes.
    final stable = Completer<void>();
    var startReturned = false;
    final sub = onStateChange.listen((state) {
      if (!startReturned) return;
      if (_isStableState(state) && !stable.isCompleted) {
        stable.complete();
      }
    });

    try {
      final (:proxyPort, :proxyAuthToken) = await _worker.start(
        hostname: hostname,
        authKey: authKey ?? '',
        controlUrl: resolvedControlUrl.toString(),
        stateDir: _stateDir,
      );
      _http = TailscaleProxyClient(proxyPort, proxyAuthToken);
      startReturned = true;

      // No-op up() case: the engine is already at a stable state and
      // won't emit another event. Check once post-start so we don't
      // wait on a state change that will never come.
      final postStart = await status();
      if (_isStableState(postStart.state) && !stable.isCompleted) {
        stable.complete();
      }

      try {
        await stable.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        final last = await status();
        throw TailscaleUpException(
          'Node did not reach a stable state within 30 seconds '
          '(last observed: ${last.state.name}). The control plane may '
          'be unreachable or the tailnet is experiencing issues.',
        );
      }
    } finally {
      await sub.cancel();
    }

    return status();
  }

  static bool _isStableState(NodeState s) =>
      s == NodeState.running ||
      s == NodeState.needsLogin ||
      s == NodeState.needsMachineAuth;

  /// Returns the current node status — lifecycle state, assigned
  /// tailnet IPs, health warnings, and MagicDNS suffix. Peer
  /// inventory is separate; call [peers] when you need it.
  ///
  /// Safe to call before [up] — returns [NodeState.stopped] when
  /// persisted credentials exist (ready to reconnect) and
  /// [NodeState.noState] when they don't.
  Future<TailscaleStatus> status() async => _worker.status(stateDir: _stateDir);

  /// Returns the current peer inventory — every node on the tailnet
  /// this node is aware of, whether online right now or not.
  ///
  /// Separate from [status] so apps can poll lightweight node state
  /// without re-pulling the full peer list on every refresh. For
  /// push-style updates, see [onPeersChange].
  Future<List<PeerStatus>> peers() async => _worker.peers();

  /// Resolves a tailnet IP to the peer's identity — stable node ID,
  /// owner login, hostname, and ACL tags — by querying the local
  /// LocalAPI.
  ///
  /// Returns null if [ip] is not known on the current tailnet.
  /// Useful for authorization decisions on incoming connections:
  /// combine with [tcp] `.bind(...)` and check
  /// [PeerIdentity.tags] before handling. See
  /// <https://tailscale.com/kb/1068/tags> for the tag model.
  Future<PeerIdentity?> whois(String ip) => _worker.whois(ip);

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
