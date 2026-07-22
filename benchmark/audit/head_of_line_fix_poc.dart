// End-to-end proof of the proposed fix (Option G): run the blocking dial in a
// HELPER isolate instead of the worker, and show status() on the worker stays
// responsive — the inverse of head_of_line.dart, which showed status() stalled
// 7.75s when the same dial ran on the worker.
//
// This calls the native dial binding directly inside Isolate.run to model
// exactly what the fixed dial path would do. Run via
// benchmark/audit/run_head_of_line.sh after pointing it at this file, or reuse
// its Headscale env.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;
import 'package:tailscale/tailscale.dart';

// Exactly what a helper-isolate dial would do: the blocking native call runs
// here, off the worker.
String _dialInHelper(List<Object> args) {
  final host = args[0] as String;
  final port = args[1] as int;
  final timeoutMillis = args[2] as int;
  final hostPtr = host.toNativeUtf8();
  try {
    final resultPtr = native.duneTcpDialFd(hostPtr, port, timeoutMillis);
    final json = resultPtr.toDartString();
    native.duneFree(resultPtr);
    return json;
  } finally {
    calloc.free(hostPtr);
  }
}

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
  final stateDir = Directory.systemTemp.createTempSync('tailscale_holfix_').path;
  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  try {
    stdout.writeln('joining Headscale…');
    await tsnet
        .up(
          hostname: 'dune-holfix-demo',
          authKey: authKey,
          controlUrl: Uri.parse(controlUrl),
        )
        .timeout(const Duration(seconds: 60));
    stdout.writeln('node state: ${(await tsnet.status()).state}');

    final base = <int>[];
    for (var i = 0; i < 7; i++) {
      base.add(await _statusMicros(tsnet));
    }
    base.sort();
    final baselineMs = base[base.length ~/ 2] / 1000.0;
    stdout.writeln('baseline status() p50: ${baselineMs.toStringAsFixed(2)} ms');

    const blockSeconds = 8;
    stdout.writeln('firing the SAME blackhole dial, but in a HELPER isolate '
        '(${blockSeconds}s)…');
    final dial = Isolate.run(
      () => _dialInHelper(<Object>['100.100.100.100', 80, blockSeconds * 1000]),
    ).then((_) => 'failed as expected', onError: (Object e) => 'error: $e');

    // Let the helper isolate enter the blocking dial, then hammer status() on
    // the worker while the dial is in flight.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final during = <int>[];
    final probeWall = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      during.add(await _statusMicros(tsnet));
    }
    probeWall.stop();
    during.sort();
    final duringMs = during[during.length ~/ 2] / 1000.0;

    stdout.writeln('dial result: ${await dial}');
    stdout.writeln('');
    stdout.writeln('=== status() p50 WHILE a helper-isolate dial blocks: '
        '${duringMs.toStringAsFixed(2)} ms '
        '(baseline ${baselineMs.toStringAsFixed(2)} ms); '
        '10 probes took ${probeWall.elapsedMilliseconds} ms total ===');
    stdout.writeln(duringMs < baselineMs * 20 && probeWall.elapsedMilliseconds < 2000
        ? 'FIX CONFIRMED: worker stayed responsive (vs 7.75s when the dial ran on the worker).'
        : 'unexpected: worker was still delayed.');
  } finally {
    try {
      await tsnet.down();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  }
}
