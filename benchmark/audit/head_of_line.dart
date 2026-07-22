// Empirical demonstration of worker-isolate head-of-line blocking (audit T1-c).
//
// The Dart control plane routes every native call through ONE worker isolate
// that processes commands synchronously in FIFO order (lib/src/worker/worker.dart
// :94). A blocking native call (tcp.dial / diag.ping / start) therefore blocks
// the isolate's event loop, so every other in-flight command — and the state/
// peer events forwarded by the same isolate — waits behind it.
//
// This joins a Headscale-controlled node, then fires a tcp.dial to an
// unreachable tailnet IP with a long timeout and measures status() latency
// while that dial is blocking the worker, versus an idle baseline.
//
// Run via benchmark/audit/run_head_of_line.sh (starts Headscale + env).
import 'dart:async';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<int> _statusMicros(Tailscale tsnet) async {
  final sw = Stopwatch()..start();
  await tsnet.status();
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<void> main() async {
  final controlUrl = Platform.environment['HEADSCALE_URL'];
  final authKey = Platform.environment['HEADSCALE_AUTH_KEY'];
  if (controlUrl == null || authKey == null) {
    stderr.writeln('Set HEADSCALE_URL and HEADSCALE_AUTH_KEY (see runner).');
    exit(2);
  }

  final stateDir = Directory.systemTemp.createTempSync('tailscale_hol_').path;
  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  try {
    stdout.writeln('joining Headscale…');
    await tsnet
        .up(
          hostname: 'dune-hol-demo',
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        )
        .timeout(const Duration(seconds: 60));
    stdout.writeln('node state: ${(await tsnet.status()).state}');

    // Idle baseline: the worker isn't blocked.
    final base = <int>[];
    for (var i = 0; i < 7; i++) {
      base.add(await _statusMicros(tsnet));
    }
    base.sort();
    final baselineMs = base[base.length ~/ 2] / 1000.0;
    stdout.writeln(
      'baseline status() p50 (idle worker): ${baselineMs.toStringAsFixed(2)} ms',
    );

    // Fire a dial to an unreachable tailnet IP; it blocks the worker for the
    // full timeout. 100.100.100.100 is a valid CGNAT/tailnet-shaped address
    // with no peer behind it, so the dial cannot connect and waits.
    const blockSeconds = 8;
    stdout.writeln(
      'firing tcp.dial(100.100.100.100:80, ${blockSeconds}s timeout) — '
      'blocks the worker isolate…',
    );
    final dial = tsnet.tcp
        .dial('100.100.100.100', 80, timeout: const Duration(seconds: blockSeconds))
        .then<String>(
          (c) {
            unawaited(c.close());
            return 'connected(!?)';
          },
          onError: (Object e) => 'failed as expected',
        );

    // Let the worker enter the blocking native call.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // status() issued now must queue behind the in-flight dial on the single
    // worker isolate.
    final sw = Stopwatch()..start();
    await tsnet.status();
    sw.stop();
    final blockedMs = sw.elapsedMilliseconds;

    final dialResult = await dial;
    stdout.writeln('dial result: $dialResult');
    stdout.writeln('');
    stdout.writeln(
      '=== status() latency while worker blocked in dial: ${blockedMs} ms '
      '(baseline ${baselineMs.toStringAsFixed(2)} ms) ===',
    );
    final verdict = blockedMs > (blockSeconds * 1000 * 0.5)
        ? 'CONFIRMED head-of-line blocking: status() stalled ~the dial timeout.'
        : 'not reproduced (status returned promptly).';
    stdout.writeln(verdict);
  } finally {
    try {
      await tsnet.down();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  }
}
