import 'dart:async';

import 'package:http/http.dart' as pkg_http;
import 'package:path/path.dart' as p;

import 'src/api/diag.dart';
import 'src/api/exit_node.dart';
import 'src/api/funnel.dart';
import 'src/api/identity.dart';
import 'src/api/prefs.dart';
import 'src/api/profiles.dart';
import 'src/api/serve.dart';
import 'src/api/taildrop.dart';
import 'src/api/tls.dart';
import 'src/errors.dart';
import 'src/ffi_bindings.dart' as native;
import 'src/http_client.dart';
import 'src/runtime_transport.dart';
import 'src/status.dart';
import 'src/tcp.dart';
import 'src/udp.dart';
import 'src/worker/worker.dart';

export 'src/api/diag.dart'
    hide
        createDiag,
        DiagPingFn,
        DiagMetricsFn,
        DiagDERPMapFn,
        DiagCheckUpdateFn;
export 'src/api/exit_node.dart';
export 'src/api/funnel.dart' hide attachFunnelMetadata;
export 'src/api/identity.dart';
export 'src/api/prefs.dart';
export 'src/api/profiles.dart';
export 'src/api/serve.dart';
export 'src/api/taildrop.dart';
export 'src/api/tls.dart' hide createTls, TlsDomainsFn;
export 'src/errors.dart';
export 'src/status.dart';
export 'src/transport.dart';

const _ownedStateSubdirectory = 'tailscale';
final Uri _defaultControlUrl = Uri.parse('https://controlplane.tailscale.com');

enum TailscaleLogLevel { silent, error, info }

extension on TailscaleLogLevel {
  int get nativeValue => switch (this) {
    TailscaleLogLevel.silent => 0,
    TailscaleLogLevel.error => 1,
    TailscaleLogLevel.info => 2,
  };
}

class Tailscale {
  Tailscale._();
  static Tailscale instance = Tailscale._();

  static String? _stateBaseDir;

  pkg_http.Client? _http;
  RuntimeTransportSession? _transport;
  List<PeerStatus>? _latestPeers;

  late final _worker = Worker(
    publishState: _stateController.add,
    publishRuntimeError: _errorController.add,
    publishPeers: _publishPeers,
  );
  late final TailscaleTcp tcp = TailscaleTcp.internal(
    _requireTransport,
    _worker,
  );
  late final TailscaleUdp udp = TailscaleUdp.internal(_requireTransport);
  late final Tls tls = createTls(domainsFn: _worker.tlsDomains);
  final Funnel funnel = Funnel.instance;
  final Taildrop taildrop = Taildrop.instance;
  final Serve serve = Serve.instance;
  final ExitNode exitNode = ExitNode.instance;
  final Profiles profiles = Profiles.instance;
  final Prefs prefs = Prefs.instance;
  late final Diag diag = createDiag(
    pingFn: (ip, timeout, type) =>
        _worker.diagPing(ip: ip, timeout: timeout, pingType: type.name),
    metricsFn: _worker.diagMetrics,
    derpMapFn: _worker.diagDERPMap,
    checkUpdateFn: _worker.diagCheckUpdate,
  );

  final StreamController<NodeState> _stateController =
      StreamController<NodeState>.broadcast();
  final StreamController<TailscaleRuntimeError> _errorController =
      StreamController<TailscaleRuntimeError>.broadcast();
  final StreamController<List<PeerStatus>> _peersController =
      StreamController<List<PeerStatus>>.broadcast();

  static String get _stateDir =>
      p.join(_stateBaseDir!, _ownedStateSubdirectory);

  void _reset() {
    unawaited(_transport?.close());
    _transport = null;
    _http?.close();
    _http = null;
    _latestPeers = null;
  }

  void _publishPeers(List<PeerStatus> peers) {
    final snapshot = List<PeerStatus>.unmodifiable(peers);
    _latestPeers = snapshot;
    _peersController.add(snapshot);
  }

  Future<List<PeerStatus>> _snapshotPeers() async {
    final peers = await _worker.peers();
    final snapshot = List<PeerStatus>.unmodifiable(peers);
    _latestPeers = snapshot;
    return snapshot;
  }

  static bool _samePeers(List<PeerStatus>? a, List<PeerStatus>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  RuntimeTransportSession _requireTransport() {
    if (_transport case RuntimeTransportSession session) {
      return session;
    }
    throw const TailscaleUsageException(
      'Call up() before accessing raw transport APIs.',
    );
  }

  pkg_http.Client get http {
    if (_http case pkg_http.Client http) {
      return http;
    }
    throw const TailscaleUsageException('Call up() before accessing http.');
  }

  Stream<NodeState> get onStateChange => _stateController.stream.distinct();

  Stream<List<PeerStatus>> get onPeersChange =>
      Stream<List<PeerStatus>>.multi((controller) {
        var canceled = false;
        List<PeerStatus>? lastEmitted;

        void emitIfChanged(List<PeerStatus> peers) {
          if (_samePeers(lastEmitted, peers)) return;
          lastEmitted = peers;
          controller.add(peers);
        }

        final subscription = _peersController.stream.listen(
          emitIfChanged,
          onError: controller.addError,
          onDone: controller.close,
        );

        unawaited(() async {
          try {
            final snapshot = _latestPeers ?? await _snapshotPeers();
            if (!canceled) {
              emitIfChanged(snapshot);
            }
          } catch (error, stackTrace) {
            if (!canceled) {
              controller.addError(error, stackTrace);
            }
          }
        }());

        controller.onCancel = () {
          canceled = true;
          return subscription.cancel();
        };
      }, isBroadcast: true);

  Stream<TailscaleRuntimeError> get onError => _errorController.stream;

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

  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    Uri? controlUrl,
  }) async {
    final resolvedControlUrl = controlUrl ?? _defaultControlUrl;

    final stable = Completer<void>();
    var startReturned = false;
    final sub = onStateChange.listen((state) {
      if (!startReturned) return;
      if (_isStableState(state) && !stable.isCompleted) {
        stable.complete();
      }
    });

    try {
      final startResult = await _worker.start(
        hostname: hostname,
        authKey: authKey ?? '',
        controlUrl: resolvedControlUrl.toString(),
        stateDir: _stateDir,
      );
      _http = TailscaleHttpClient.forWorker(_worker);

      if (startResult.transportMasterSecretB64 == null ||
          startResult.transportSessionGenerationIdB64 == null ||
          startResult.transportPreferredCarrierKind == null) {
        throw const TailscaleUpException(
          'Native runtime did not return transport bootstrap details.',
        );
      }

      final bootstrap = RuntimeTransportBootstrap(
        masterSecretB64: startResult.transportMasterSecretB64!,
        sessionGenerationIdB64: startResult.transportSessionGenerationIdB64!,
        preferredCarrierKind: startResult.transportPreferredCarrierKind!,
      );

      final existingTransport = _transport;
      if (existingTransport == null ||
          !existingTransport.matchesBootstrap(bootstrap)) {
        if (existingTransport != null) {
          await existingTransport.close();
          _transport = null;
        }
        _transport = await RuntimeTransportSession.start(
          bootstrap: bootstrap,
          worker: _worker,
          publishRuntimeError: _errorController.add,
        );
      }

      startReturned = true;

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

  Future<int> listen(int localPort, {int tailnetPort = 80}) async {
    return _worker.listen(localPort: localPort, tailnetPort: tailnetPort);
  }

  Future<TailscaleStatus> status() async => _worker.status(stateDir: _stateDir);

  Future<List<PeerStatus>> peers() => _snapshotPeers();

  Future<PeerIdentity?> whois(String ip) => _worker.whois(ip);

  Future<void> down() async {
    _reset();
    await _worker.down();
  }

  Future<void> logout() async {
    _reset();
    await _worker.logout(_stateDir);
  }
}
