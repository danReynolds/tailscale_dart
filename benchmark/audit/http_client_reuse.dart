// Exploratory latency probe for HTTP client connection reuse (audit T2-a). The
// node binds a trivial tailnet HTTP server and makes N sequential GETs to its
// own tailnet IP.
//
// NOTE: over netstack loopback a dial is near-free, so this shows FLAT latency
// whether or not connections are reused — it does NOT by itself prove reuse.
// The definitive, hermetic proof of reuse (dial counts via a counting dialer)
// lives in go/http_transport_cache_test.go. The temporary Go-side dial-count
// instrumentation this comment once referenced was removed; run those unit
// tests, not this script, to verify the dial-count behavior.
//
// Run via benchmark/audit/run_http_reuse.sh (Headscale + env).
import 'dart:async';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  final controlUrl = Platform.environment['HEADSCALE_URL'];
  final authKey = Platform.environment['HEADSCALE_AUTH_KEY'];
  if (controlUrl == null || authKey == null) {
    stderr.writeln('Set HEADSCALE_URL and HEADSCALE_AUTH_KEY (see runner).');
    exit(2);
  }

  final stateDir = Directory.systemTemp.createTempSync('ts_httpreuse_').path;
  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  try {
    await tsnet
        .up(
          hostname: 'dune-httpreuse',
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        )
        .timeout(const Duration(seconds: 60));
    String? selfIp;
    for (var i = 0; i < 60; i++) {
      selfIp = (await tsnet.status()).ipv4;
      if (selfIp != null && selfIp.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (selfIp == null || selfIp.isEmpty) {
      throw StateError('node never got a tailnet IPv4');
    }
    stdout.writeln('node up: $selfIp');

    final server = await tsnet.http.bind(port: 8080);
    server.requests.listen((req) async {
      await req.respond(body: 'ok');
    });
    await Future<void>.delayed(const Duration(seconds: 1));

    const n = 15;
    final latencies = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      final resp = await tsnet.http.client
          .get(Uri.parse('http://$selfIp:8080/'))
          .timeout(const Duration(seconds: 15));
      sw.stop();
      if (resp.statusCode != 200) {
        throw StateError('unexpected status ${resp.statusCode}');
      }
      latencies.add(sw.elapsedMicroseconds);
      stdout.writeln(
        'req ${i + 1}: ${(sw.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms',
      );
    }
    final total = latencies.reduce((a, b) => a + b);
    latencies.sort();
    stdout.writeln('');
    stdout.writeln(
      '$n sequential GETs: total ${(total / 1000).toStringAsFixed(1)} ms, '
      'p50 ${(latencies[n ~/ 2] / 1000).toStringAsFixed(2)} ms, '
      'first ${(latencies.first / 1000).toStringAsFixed(2)}..'
      'max ${(latencies.last / 1000).toStringAsFixed(2)} ms',
    );
    stdout.writeln(
      'Check the "[bench] http dials so far" lines: climbing 1..$n = no reuse; '
      'flat at 1 = full reuse.',
    );
  } finally {
    try {
      await tsnet.down();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  }
}
