// Validates the load-bearing assumptions behind a Dart-side concurrency fix for
// worker head-of-line blocking:
//
//  A1. Multiple Dart isolates each making a BLOCKING FFI call run CONCURRENTLY
//      (wall time ≈ 1× the block, not N×) — i.e. isolates give real FFI
//      parallelism, so a blocking call on one isolate doesn't stall others.
//  A2. FFI (@Native / DynamicLibrary) works inside Isolate.run — required for
//      the "ephemeral helper isolate per blocking call" design.
//  A3. A slow FFI call on one isolate does not delay many fast FFI calls on
//      another isolate (the actual head-of-line property we need).
//
// Uses libc usleep() as a synchronous blocking native call, so this needs no
// tailscale node.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:tailscale/src/ffi_bindings.dart' as native;

typedef _UsleepC = Int32 Function(Uint32);
typedef _UsleepD = int Function(int);

int _usleep(int micros) {
  final f = DynamicLibrary.process().lookupFunction<_UsleepC, _UsleepD>(
    'usleep',
  );
  return f(micros);
}

// Top-level so it can run as an Isolate.spawn entrypoint.
void _blockingWorker(List<Object> args) {
  final reply = args[0] as SendPort;
  final micros = args[1] as int;
  final sw = Stopwatch()..start();
  _usleep(micros); // blocks THIS isolate's thread in native code
  sw.stop();
  reply.send(sw.elapsedMicroseconds);
}

Future<int> _spawnBlocking(int micros) async {
  final reply = ReceivePort();
  await Isolate.spawn(_blockingWorker, <Object>[reply.sendPort, micros]);
  final elapsed = await reply.first as int;
  reply.close();
  return elapsed;
}

Future<void> main() async {
  print('=== A1: N isolates each usleep(500ms) — concurrent or serialized? ===');
  for (final n in [1, 4, 8]) {
    final sw = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < n; i++) _spawnBlocking(500 * 1000)]);
    sw.stop();
    final wall = sw.elapsedMilliseconds;
    print('  n=$n: wall=${wall}ms '
        '(${wall < 500 * 2 ? "CONCURRENT" : "SERIALIZED (~${wall ~/ 500}x)"})');
  }

  print('');
  print('=== A2: FFI inside Isolate.run ===');
  final runResult = await Isolate.run(() {
    _usleep(1000); // 1ms
    return 'usleep via Isolate.run returned ok';
  });
  print('  $runResult');

  print('');
  print('=== A4: REAL @Native binding (duneReactorCreate) in Isolate.run ===');
  final handle = await Isolate.run(() {
    final h = native.duneReactorCreate();
    if (h >= 0) native.duneReactorClose(h);
    return h;
  });
  print('  duneReactorCreate() in Isolate.run -> $handle '
      '(${handle >= 0 ? "WORKS: @Native resolves in a helper isolate" : "FAILED"})');

  print('');
  print('=== A2b: Isolate.run spawn overhead (per blocking call) ===');
  // Warm up.
  await Isolate.run(() => 0);
  final spawn = <int>[];
  for (var i = 0; i < 20; i++) {
    final sw = Stopwatch()..start();
    await Isolate.run(() => 0);
    sw.stop();
    spawn.add(sw.elapsedMicroseconds);
  }
  spawn.sort();
  print('  Isolate.run round-trip: p50=${(spawn[10] / 1000).toStringAsFixed(2)}ms '
      'p95=${(spawn[19] / 1000).toStringAsFixed(2)}ms (overhead per blocking call)');

  print('');
  print('=== A3: one slow isolate (usleep 2s) must not delay fast calls '
      'on another isolate ===');
  final slow = _spawnBlocking(2 * 1000 * 1000); // 2s on its own isolate
  await Future<void>.delayed(const Duration(milliseconds: 50));
  // Fire many fast blocking calls on their own isolates while the slow one runs.
  final fast = <int>[];
  final fastWall = Stopwatch()..start();
  for (var i = 0; i < 10; i++) {
    fast.add(await _spawnBlocking(1000)); // 1ms each, sequential spawns
  }
  fastWall.stop();
  final slowElapsed = await slow;
  print('  10 fast (1ms) calls completed in ${fastWall.elapsedMilliseconds}ms '
      'while a 2s call ran concurrently (slow took ${slowElapsed ~/ 1000}ms)');
  print('  => fast calls were ${fastWall.elapsedMilliseconds < 1500 ? "NOT blocked" : "BLOCKED"} '
      'by the slow one.');
}
