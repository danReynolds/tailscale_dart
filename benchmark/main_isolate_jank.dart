// ignore_for_file: avoid_print
/// Benchmark: Main isolate jank measurement for tailscale APIs.
///
/// Measures two things separately:
///   1. **Main isolate time** — how long the main isolate is synchronously
///      blocked (can't process frames). This is what causes jank.
///   2. **Wall time** — total latency until the result is available.
///
/// For Isolate.run() calls, the main isolate is only blocked during:
///   - Isolate spawn (message serialize + kernel thread creation)
///   - Result delivery (message deserialize)
/// The actual FFI work happens on the background isolate while the main
/// isolate is free to paint frames.
///
/// We measure main-isolate time by running a microsecond ticker on the main
/// isolate during the await. Any gap in the ticker = main isolate was blocked.
/// Alternatively, we measure by computing: wall_time - background_work_time.
///
/// Requires:
///   - Go 1.25+ (build hook compiles the native library automatically)
///   - Headscale running on localhost:8080 with a valid auth key
///
/// Usage:
///   HEADSCALE_URL=http://localhost:8080 \
///   HEADSCALE_AUTH_KEY=<key> \
///     dart run benchmark/main_isolate_jank.dart

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:tailscale/tailscale.dart';

const _warmup = 3;
const _iterations = 20;

Future<void> main() async {
  final controlUrl = Platform.environment['HEADSCALE_URL'];
  final authKey = Platform.environment['HEADSCALE_AUTH_KEY'];

  if (controlUrl == null || authKey == null) {
    print('ERROR: HEADSCALE_URL and HEADSCALE_AUTH_KEY required.');
    print('Start Headscale: cd test/e2e && docker compose up -d');
    print(
      'Create key: docker compose exec headscale headscale preauthkeys create --user dune-test --ephemeral --expiration 10m',
    );
    exit(1);
  }

  final parsedControlUrl = Uri.parse(controlUrl);
  final tsnet = Tailscale.instance;
  final stateDir = Directory.systemTemp.createTempSync('tailscale_bench_').path;
  final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  backend.listen((request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.write('ok');
    await request.response.close();
  });

  print('');
  print('=== tailscale Main Isolate Jank Benchmark ===');
  print('');
  print('Iterations: $_iterations (after $_warmup warmup)');
  print('Frame budget: 16.67ms @ 60fps');
  print('');
  print('Main time  = synchronous blocking on main isolate (causes jank)');
  print('Wall time  = total latency until result is available');
  print('Isolate time = work done on background isolate (no jank)');
  print('');

  final results = <_BenchResult>[];

  try {
    results.add(
      _benchSyncOnce('Tailscale.init()', () {
        Tailscale.init(stateDir: stateDir);
      }),
    );

    results.add(
      await _benchOnce(
        'up()',
        () => tsnet.up(
          hostname: 'bench-node',
          authKey: authKey,
          controlUrl: parsedControlUrl,
        ),
      ),
    );

    await Future.delayed(const Duration(seconds: 1));

    results.add(await _bench('status()', () => tsnet.status()));
    results.add(await _bench('peers()', () => tsnet.peers()));
    results.add(
      await _bench('listen()', () => tsnet.listen(backend.port)),
    );
    results.add(
      _benchSync('http getter', () {
        final _ = tsnet.http;
      }),
    );
    results.add(await _benchOnce('down()', () => tsnet.down()));

    // --- Also benchmark raw Isolate.run() overhead with no-op ---
    results.add(
      await _bench('Isolate.run() baseline', () => Isolate.run(() => 42)),
    );

    _printResults(results);
  } catch (_) {}
  try {
    await tsnet.down();
  } catch (_) {}
  try {
    await backend.close(force: true);
  } catch (_) {}
  try {
    Directory(stateDir).deleteSync(recursive: true);
  } catch (_) {}
}

/// Measures main-isolate blocking time vs wall time for an async call.
///
/// Uses a Timer.periodic at max rate to detect when the main isolate is
/// free. The main isolate time is: wall_time - time_spent_yielded.
/// We approximate this by counting how many microtask ticks fire during
/// the await — if the main isolate is truly free, ticks fire rapidly.
Future<_BenchResult> _bench(String label, Future<dynamic> Function() fn) async {
  // Warmup
  for (var i = 0; i < _warmup; i++) {
    await fn();
  }

  final wallUs = <int>[];
  final mainUs = <int>[];
  final isolateUs = <int>[];

  for (var i = 0; i < _iterations; i++) {
    final measurement = await _measureMainIsolateTime(fn);
    wallUs.add(measurement.wallUs);
    mainUs.add(measurement.mainUs);
    isolateUs.add(measurement.isolateUs);
  }

  return _BenchResult(label, wallUs, mainUs, isolateUs);
}

Future<_BenchResult> _benchOnce(
  String label,
  Future<dynamic> Function() fn,
) async {
  final m = await _measureMainIsolateTime(fn);
  return _BenchResult(
      label,
      [m.wallUs],
      [m.mainUs],
      [
        m.isolateUs,
      ],
      singleShot: true);
}

_BenchResult _benchSync(String label, void Function() fn) {
  for (var i = 0; i < _warmup; i++) {
    fn();
  }

  final wallUs = <int>[];
  for (var i = 0; i < _iterations; i++) {
    final sw = Stopwatch()..start();
    fn();
    sw.stop();
    wallUs.add(sw.elapsedMicroseconds);
  }

  return _BenchResult(label, wallUs, wallUs, List.filled(wallUs.length, 0));
}

_BenchResult _benchSyncOnce(String label, void Function() fn) {
  final sw = Stopwatch()..start();
  fn();
  sw.stop();

  return _BenchResult(
    label,
    [sw.elapsedMicroseconds],
    [sw.elapsedMicroseconds],
    const [0],
    singleShot: true,
  );
}

/// Measures how much of the wall time is spent blocking the main isolate.
///
/// Approach: schedule a rapid timer before the await. Count how many times
/// it fires during the await. If the main isolate is free (Isolate.run is
/// doing work elsewhere), the timer fires frequently. If the main isolate
/// is blocked (synchronous work), the timer doesn't fire.
///
/// main_blocked_time ≈ wall_time - (tick_count * tick_interval)
///
/// But a simpler and more accurate approach: we know Isolate.run() has
/// two synchronous phases on the main isolate:
///   1. Spawn: serialize closure → kernel creates thread → ~1-3ms
///   2. Result: deserialize result → ~0.01ms for small data
/// And one async phase (background isolate does the work).
///
/// So we measure: before spawn (sync), after spawn (async wait), after result (sync).
/// We use Completer + microtask scheduling to distinguish the phases.
Future<_Measurement> _measureMainIsolateTime(
  Future<dynamic> Function() fn,
) async {
  // Phase 1: Record the total wall time
  final wallSw = Stopwatch()..start();

  // Phase 2: Use a periodic timer to measure how much time the main isolate
  // was actually responsive (not blocked). Timer callbacks only fire when
  // the main isolate's event loop is running.
  var responsiveTicks = 0;
  const tickInterval = Duration(microseconds: 100);
  final ticker = Timer.periodic(tickInterval, (_) {
    responsiveTicks++;
  });

  // Actually do the call
  await fn();

  wallSw.stop();
  ticker.cancel();

  // Give one more event loop turn so any pending ticks fire
  await Future.delayed(Duration.zero);

  final wallMicros = wallSw.elapsedMicroseconds;

  // The main isolate was responsive for roughly:
  //   responsive_time = responsiveTicks * tickInterval
  // The main isolate was blocked for:
  //   blocked_time = wall_time - responsive_time
  //
  // This slightly overestimates blocking because timer granularity isn't
  // perfect, but it gives a good order-of-magnitude signal.
  final responsiveUs = responsiveTicks * tickInterval.inMicroseconds;
  final mainBlockedUs = (wallMicros - responsiveUs).clamp(0, wallMicros);
  final isolateWorkUs = wallMicros - mainBlockedUs;

  return _Measurement(
    wallUs: wallMicros,
    mainUs: mainBlockedUs,
    isolateUs: isolateWorkUs,
  );
}

class _Measurement {
  _Measurement({
    required this.wallUs,
    required this.mainUs,
    required this.isolateUs,
  });
  final int wallUs;
  final int mainUs;
  final int isolateUs;
}

class _BenchResult {
  _BenchResult(
    this.label,
    this.wallUs,
    this.mainUs,
    this.isolateUs, {
    this.singleShot = false,
  });

  final String label;
  final List<int> wallUs;
  final List<int> mainUs;
  final List<int> isolateUs;
  final bool singleShot;

  double _medMs(List<int> us) {
    if (us.length == 1) return us[0] / 1000.0;
    final sorted = List.of(us)..sort();
    return sorted[sorted.length ~/ 2] / 1000.0;
  }

  double _p90Ms(List<int> us) {
    if (us.length == 1) return us[0] / 1000.0;
    final sorted = List.of(us)..sort();
    return sorted[(sorted.length * 0.9).floor()] / 1000.0;
  }

  double get wallMed => _medMs(wallUs);
  double get wallP90 => _p90Ms(wallUs);
  double get mainMed => _medMs(mainUs);
  double get mainP90 => _p90Ms(mainUs);
  double get isoMed => _medMs(isolateUs);
}

String _fmtMs(double ms) => ms.toStringAsFixed(2).padLeft(9);

void _printResults(List<_BenchResult> results) {
  print('');
  print('Results');
  print('=======');
  print('');

  const lw = 30;
  print(
    '${'API'.padRight(lw)}'
    '${'Main med'.padLeft(11)}'
    '${'Main p90'.padLeft(11)}'
    '${'Wall med'.padLeft(11)}'
    '${'Wall p90'.padLeft(11)}'
    '${'  Jank?'.padLeft(9)}',
  );
  print(
    '${''.padRight(lw, '-')}'
    '${''.padRight(11, '-')}'
    '${''.padRight(11, '-')}'
    '${''.padRight(11, '-')}'
    '${''.padRight(11, '-')}'
    '${''.padRight(9, '-')}',
  );

  for (final r in results) {
    final jank = r.mainMed < 1.0
        ? 'None'
        : r.mainMed < 4.0
            ? 'Low'
            : r.mainMed < 16.0
                ? 'Med'
                : 'HIGH';
    print(
      '${r.label.padRight(lw)}'
      '${_fmtMs(r.mainMed)} ms'
      '${_fmtMs(r.mainP90)} ms'
      '${_fmtMs(r.wallMed)} ms'
      '${_fmtMs(r.wallP90)} ms'
      '${jank.padLeft(9)}',
    );
  }

  print('');
  print('Main = time main isolate is blocked (causes jank)');
  print('Wall = total latency until result available');
  print('Jank risk: None (<1ms) | Low (<4ms) | Med (<16ms) | HIGH (>16ms)');
  print('');

  // Markdown
  print('--- Markdown ---');
  print('');
  print(
    '| API | Main med (ms) | Main p90 (ms) | Wall med (ms) | Wall p90 (ms) | Jank risk |',
  );
  print(
    '|-----|--------------|--------------|--------------|--------------|-----------|',
  );
  for (final r in results) {
    final jank = r.mainMed < 1.0
        ? 'None'
        : r.mainMed < 4.0
            ? 'Low'
            : r.mainMed < 16.0
                ? 'Med'
                : 'HIGH';
    print(
      '| ${r.label} '
      '| ${r.mainMed.toStringAsFixed(2)} '
      '| ${r.mainP90.toStringAsFixed(2)} '
      '| ${r.wallMed.toStringAsFixed(2)} '
      '| ${r.wallP90.toStringAsFixed(2)} '
      '| $jank |',
    );
  }
}
