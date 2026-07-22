// Rigorous isolate spawn-cost measurement, because the one-off-vs-pool decision
// hinges on it. Reports the COLD first spawn and the full distribution (not
// just p50), for both Isolate.run and the killable Isolate.spawn+kill variant.
import 'dart:async';
import 'dart:isolate';

void _noop(SendPort p) => p.send(0);

Future<void> _spawnKillRoundTrip() async {
  final reply = ReceivePort();
  final iso = await Isolate.spawn(_noop, reply.sendPort);
  await reply.first;
  reply.close();
  iso.kill(priority: Isolate.immediate);
}

String _stats(List<int> micros) {
  micros.sort();
  double at(double q) => micros[(micros.length * q).clamp(0, micros.length - 1).toInt()] / 1000.0;
  final mean = micros.reduce((a, b) => a + b) / micros.length / 1000.0;
  return 'p50=${at(0.5).toStringAsFixed(2)} p95=${at(0.95).toStringAsFixed(2)} '
      'p99=${at(0.99).toStringAsFixed(2)} max=${(micros.last / 1000).toStringAsFixed(2)} '
      'mean=${mean.toStringAsFixed(2)} ms';
}

Future<void> main() async {
  const n = 500;

  // COLD: the very first spawn in the process, before any warmup.
  final cold = Stopwatch()..start();
  await Isolate.run(() => 0);
  cold.stop();
  print('COLD first Isolate.run: ${(cold.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms');

  // Isolate.run round-trip.
  final run = <int>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await Isolate.run(() => 0);
    sw.stop();
    run.add(sw.elapsedMicroseconds);
  }
  print('Isolate.run x$n:        ${_stats(run)}');

  // Isolate.spawn + kill round-trip (the killable variant for cancellation).
  await _spawnKillRoundTrip(); // warm
  final spawn = <int>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await _spawnKillRoundTrip();
    sw.stop();
    spawn.add(sw.elapsedMicroseconds);
  }
  print('Isolate.spawn+kill x$n: ${_stats(spawn)}');

  // Sustained concurrent churn: 200 spawns in flight at once (models a burst of
  // concurrent dials), to surface any per-isolate cost that only shows at scale.
  final burst = Stopwatch()..start();
  await Future.wait([for (var i = 0; i < 200; i++) Isolate.run(() => 0)]);
  burst.stop();
  print('200 concurrent Isolate.run: ${burst.elapsedMilliseconds} ms total '
      '(${(burst.elapsedMilliseconds / 200).toStringAsFixed(2)} ms/each amortized)');
}
