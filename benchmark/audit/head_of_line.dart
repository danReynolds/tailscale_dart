// Regression benchmark for worker-isolate head-of-line blocking (audit T1-c).
//
// Long-running TCP dials are offloaded from the worker isolate. This joins a
// Headscale-controlled node, dials an unreachable tailnet IP with a long
// timeout, and verifies that status() remains responsive while the dial is in
// flight.
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
  Tailscale.init(
    stateDir: stateDir,
    appId: 'dev.tailscale.dart.benchmark.headOfLine',
  );
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
      'baseline status() p50: ${baselineMs.toStringAsFixed(2)} ms',
    );

    // Fire a dial to an unreachable tailnet IP; it blocks the worker for the
    // full timeout. 100.100.100.100 is a valid CGNAT/tailnet-shaped address
    // with no peer behind it, so the dial cannot connect and waits.
    const blockSeconds = 8;
    stdout.writeln(
      'firing tcp.dial(100.100.100.100:80, ${blockSeconds}s timeout)…',
    );
    final dial = tsnet.tcp
        .dial(
          '100.100.100.100',
          80,
          timeout: const Duration(seconds: blockSeconds),
        )
        .then<String>((c) {
          unawaited(c.close());
          return 'connected(!?)';
        }, onError: (Object e) => 'failed as expected');

    // Let the helper isolate enter the blocking native call.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // status() must not queue behind the in-flight dial.
    final sw = Stopwatch()..start();
    await tsnet.status();
    sw.stop();
    final blockedMs = sw.elapsedMilliseconds;

    final dialResult = await dial;
    stdout.writeln('dial result: $dialResult');
    stdout.writeln('');
    stdout.writeln(
      '=== status() latency while dial is in flight: $blockedMs ms '
      '(baseline ${baselineMs.toStringAsFixed(2)} ms) ===',
    );
    final verdict = blockedMs < 2000
        ? 'PASS: worker remained responsive.'
        : 'FAIL: status() stalled behind the dial.';
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
