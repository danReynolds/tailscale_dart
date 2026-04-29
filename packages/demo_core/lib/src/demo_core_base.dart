import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tailscale/tailscale.dart';

import 'auth_keys.dart';

const demoDefaultHttpPort = 8080;
const demoDefaultTcpPort = 7000;
const demoDefaultUdpPort = 7001;

final class DemoServiceConfig {
  const DemoServiceConfig({
    this.httpTailnetPort = demoDefaultHttpPort,
    this.tcpPort = demoDefaultTcpPort,
    this.udpPort = demoDefaultUdpPort,
  });

  final int httpTailnetPort;
  final int tcpPort;
  final int udpPort;
}

final class DemoServices {
  const DemoServices({
    required this.localIp,
    required this.httpTailnetPort,
    required this.tcpPort,
    required this.udpPort,
  });

  final String localIp;
  final int httpTailnetPort;
  final int tcpPort;
  final int udpPort;

  @override
  String toString() =>
      'DemoServices(ip: $localIp, http: $httpTailnetPort, '
      'tcp: $tcpPort, udp: $udpPort)';
}

enum DemoProbeKind {
  ping,
  whois,
  httpGet,
  httpPost,
  tcpEcho,
  udpEcho;

  String get label => switch (this) {
    ping => 'Ping',
    whois => 'WhoIs',
    httpGet => 'HTTP GET',
    httpPost => 'HTTP POST',
    tcpEcho => 'TCP echo',
    udpEcho => 'UDP echo',
  };
}

final class DemoProbeResult {
  const DemoProbeResult({
    required this.kind,
    required this.ok,
    required this.duration,
    required this.message,
  });

  final DemoProbeKind kind;
  final bool ok;
  final Duration duration;
  final String message;
}

final class DemoProbeReport {
  const DemoProbeReport({required this.nodeIp, required this.results});

  final String nodeIp;
  final List<DemoProbeResult> results;

  bool get ok => results.every((result) => result.ok);
}

final class DemoCore {
  DemoCore({Tailscale? tailscale}) : _tsnet = tailscale ?? Tailscale.instance;

  final Tailscale _tsnet;
  String _hostname = '';
  DemoServices? _services;
  TailscaleHttpServer? _httpServer;
  StreamSubscription<TailscaleHttpRequest>? _httpRequests;
  TailscaleListener? _tcpListener;
  StreamSubscription<TailscaleConnection>? _tcpConnections;
  TailscaleDatagramBinding? _udpBinding;
  StreamSubscription<TailscaleDatagram>? _udpDatagrams;

  Stream<NodeState> get onStateChange => _tsnet.onStateChange;
  Stream<TailscaleRuntimeError> get onError => _tsnet.onError;
  Stream<List<TailscaleNode>> get onNodeChanges => _tsnet.onNodeChanges;

  DemoServices? get services => _services;

  Future<TailscaleStatus> up({
    required String stateDir,
    required String hostname,
    String? authKey,
    Uri? controlUrl,
    TailscaleLogLevel logLevel = TailscaleLogLevel.info,
  }) async {
    await stopServices();
    _hostname = hostname;
    Tailscale.init(stateDir: stateDir, logLevel: logLevel);
    return _tsnet.up(
      hostname: hostname,
      authKey: authKey == null || authKey.isEmpty ? null : authKey,
      controlUrl: controlUrl,
    );
  }

  Future<TailscaleStatus> status() => _tsnet.status();

  Future<List<TailscaleNode>> nodes() => _tsnet.nodes();

  Future<DemoGeneratedAuthKey> generateAuthKey({
    required String apiKey,
    required String tailnetId,
    bool reusable = false,
    bool ephemeral = false,
    bool preauthorized = true,
    Duration expiry = const Duration(days: 1),
  }) {
    return createDemoAuthKey(
      DemoAuthKeyRequest(
        apiKey: apiKey,
        tailnetId: tailnetId,
        reusable: reusable,
        ephemeral: ephemeral,
        preauthorized: preauthorized,
        expiry: expiry,
      ),
    );
  }

  Future<TailscaleStatus> upAsAdmin({
    required String stateDir,
    required String hostname,
    required String apiKey,
    required String tailnetId,
    Uri? controlUrl,
    TailscaleLogLevel logLevel = TailscaleLogLevel.info,
  }) async {
    final generated = await generateAuthKey(
      apiKey: apiKey,
      tailnetId: tailnetId,
    );
    return up(
      stateDir: stateDir,
      hostname: hostname,
      authKey: generated.key,
      controlUrl: controlUrl,
      logLevel: logLevel,
    );
  }

  Future<DemoServices> startServices({
    DemoServiceConfig config = const DemoServiceConfig(),
  }) async {
    final status = await _tsnet.status();
    final localIp = status.ipv4;
    if (localIp == null || localIp.isEmpty) {
      throw StateError('Tailscale node has no IPv4 address yet.');
    }

    final existing = _services;
    if (existing != null) {
      if (existing.localIp == localIp) return existing;
      await stopServices();
    }

    final httpServer = await _tsnet.http.bind(port: config.httpTailnetPort);
    _httpServer = httpServer;
    _httpRequests = httpServer.requests.listen(_handleHttpRequest);

    final tcpListener = await _tsnet.tcp.bind(port: config.tcpPort);
    _tcpListener = tcpListener;
    _tcpConnections = tcpListener.connections.listen(_handleTcpConnection);

    final udpBinding = await _tsnet.udp.bind(
      address: localIp,
      port: config.udpPort,
    );
    _udpBinding = udpBinding;
    _udpDatagrams = udpBinding.datagrams.listen(_handleUdpDatagram);

    return _services = DemoServices(
      localIp: localIp,
      httpTailnetPort: config.httpTailnetPort,
      tcpPort: config.tcpPort,
      udpPort: config.udpPort,
    );
  }

  Future<void> stopServices() async {
    final futures = <Future<void>>[];
    final httpRequests = _httpRequests;
    if (httpRequests != null) futures.add(httpRequests.cancel());
    final tcpConnections = _tcpConnections;
    if (tcpConnections != null) futures.add(tcpConnections.cancel());
    final udpDatagrams = _udpDatagrams;
    if (udpDatagrams != null) futures.add(udpDatagrams.cancel());
    final tcpListener = _tcpListener;
    if (tcpListener != null) futures.add(tcpListener.close());
    final udpBinding = _udpBinding;
    if (udpBinding != null) futures.add(udpBinding.close());
    final httpServer = _httpServer;
    if (httpServer != null) futures.add(httpServer.close());
    await Future.wait(futures);
    _services = null;
    _httpServer = null;
    _httpRequests = null;
    _tcpListener = null;
    _tcpConnections = null;
    _udpBinding = null;
    _udpDatagrams = null;
  }

  Future<void> down() async {
    await stopServices();
    await _tsnet.down();
  }

  Future<DemoProbeReport> probeNode(
    String nodeIp, {
    DemoServiceConfig config = const DemoServiceConfig(),
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // Probes are sequential. Parallelizing all six fd-backed probes hit the
    // per-fd-isolate scaling ceiling described in docs/rfc-shared-fd-reactor.md
    // — measured ~5.2s per probe vs ~50ms sequential. Revisit once the shared
    // POSIX fd reactor lands.
    final results = <DemoProbeResult>[];
    results.add(
      await _runProbe(DemoProbeKind.ping, () async {
        final result = await _tsnet.diag.ping(nodeIp, timeout: timeout);
        return 'latency ${result.latency.inMilliseconds}ms via ${result.path.name}';
      }),
    );
    results.add(
      await _runProbe(DemoProbeKind.whois, () async {
        final identity = await _tsnet.whois(nodeIp);
        if (identity == null) throw StateError('node identity not found');
        return identity.hostName;
      }),
    );
    results.add(
      await _runProbe(DemoProbeKind.httpGet, () async {
        final uri = Uri.parse('http://$nodeIp:${config.httpTailnetPort}/demo');
        final response = await _tsnet.http.client.get(uri).timeout(timeout);
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode}');
        }
        return response.body;
      }),
    );
    results.add(
      await _runProbe(DemoProbeKind.httpPost, () async {
        final payload = _payload('http');
        final uri = Uri.parse('http://$nodeIp:${config.httpTailnetPort}/echo');
        final response = await _tsnet.http.client
            .post(uri, body: payload)
            .timeout(timeout);
        if (response.body != 'echo: $payload') {
          throw StateError('unexpected body ${response.body}');
        }
        return 'echoed ${payload.length} bytes';
      }),
    );
    results.add(
      await _runProbe(DemoProbeKind.tcpEcho, () async {
        final payload = utf8.encode(_payload('tcp'));
        final conn = await _tsnet.tcp
            .dial(nodeIp, config.tcpPort, timeout: timeout)
            .timeout(timeout);
        try {
          await conn.output.write(payload);
          await conn.output.close();
          final received = await _readBytes(
            conn.input,
            payload.length,
            timeout,
          );
          if (!_listEquals(received, payload)) {
            throw StateError('TCP echo mismatch');
          }
          return 'echoed ${payload.length} bytes';
        } finally {
          await conn.close();
        }
      }),
    );
    results.add(
      await _runProbe(DemoProbeKind.udpEcho, () async {
        final status = await _tsnet.status();
        final localIp = status.ipv4;
        if (localIp == null || localIp.isEmpty) {
          throw StateError('local node has no IPv4 address');
        }
        final binding = await _tsnet.udp
            .bind(address: localIp, port: 0)
            .timeout(timeout);
        final iterator = StreamIterator(binding.datagrams);
        try {
          final payload = utf8.encode(_payload('udp'));
          final first = iterator.moveNext().timeout(timeout);
          await Future<void>.delayed(Duration.zero);
          await binding.send(
            payload,
            to: TailscaleEndpoint(address: nodeIp, port: config.udpPort),
          );
          if (!await first) throw StateError('no UDP response');
          if (!_listEquals(iterator.current.payload, payload)) {
            throw StateError('UDP echo mismatch');
          }
          return 'echoed ${payload.length} bytes from ${iterator.current.remote}';
        } finally {
          await iterator.cancel();
          await binding.close();
        }
      }),
    );

    return DemoProbeReport(
      nodeIp: nodeIp,
      results: List<DemoProbeResult>.unmodifiable(results),
    );
  }

  Future<DemoProbeResult> _runProbe(
    DemoProbeKind kind,
    Future<String> Function() probe,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final message = await probe();
      return DemoProbeResult(
        kind: kind,
        ok: true,
        duration: sw.elapsed,
        message: message,
      );
    } catch (error) {
      return DemoProbeResult(
        kind: kind,
        ok: false,
        duration: sw.elapsed,
        message: error.toString(),
      );
    }
  }

  Future<void> _handleHttpRequest(TailscaleHttpRequest request) async {
    if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request.body).join();
      await request.respond(
        headers: {'content-type': 'text/plain'},
        body: 'echo: $body',
      );
    } else {
      await request.respond(
        headers: {'content-type': 'text/plain'},
        body: 'demo-http:${_hostname.isEmpty ? 'node' : _hostname}',
      );
    }
  }

  void _handleTcpConnection(TailscaleConnection conn) {
    unawaited(
      conn.output
          .writeAll(conn.input, close: true)
          .catchError((_) => conn.abort()),
    );
  }

  void _handleUdpDatagram(TailscaleDatagram datagram) {
    final binding = _udpBinding;
    if (binding == null) return;
    unawaited(binding.send(datagram.payload, to: datagram.remote));
  }

  static String _payload(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  static Future<List<int>> _readBytes(
    Stream<Uint8List> input,
    int length,
    Duration timeout,
  ) async {
    final builder = BytesBuilder();
    await for (final chunk in input.timeout(
      timeout,
      onTimeout: (sink) => sink.close(),
    )) {
      builder.add(chunk);
      if (builder.length >= length) break;
    }
    final bytes = builder.takeBytes();
    if (bytes.length < length) {
      throw StateError('expected $length bytes, received ${bytes.length}');
    }
    return bytes.sublist(0, length);
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
