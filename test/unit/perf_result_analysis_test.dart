import 'package:test/test.dart';

import '../../benchmark/profile/result_analysis.dart';

void main() {
  test('perfPercentile uses the sorted nearest sample', () {
    expect(perfPercentile(<double>[9, 1, 5, 3, 7], 0.50), 5);
    expect(perfPercentile(<double>[9, 1, 5, 3, 7], 0.95), 9);
  });

  test('summarizes samples across trials', () {
    final comparisons = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'control.status', <num>[1000, 1200]),
      _metric('release', 'control.status', <num>[1100, 1300]),
      _metric('current', 'control.status', <num>[700, 800]),
      _metric('current', 'control.status', <num>[750, 850]),
    ]);

    expect(comparisons, hasLength(1));
    final result = comparisons.single;
    expect(result.baselineSamples, <double>[1000, 1200, 1100, 1300]);
    expect(result.currentSamples, <double>[700, 800, 750, 850]);
    expect(result.baselineP50, 1200);
    expect(result.currentP50, 800);
    expect(result.verdict, 'improvement');
  });

  test('understands higher-is-better throughput', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      _metric(
        'release',
        'tcp.throughput',
        <num>[100, 105, 110],
        unit: 'mib_per_second',
        higherIsBetter: true,
      ),
      _metric(
        'current',
        'tcp.throughput',
        <num>[70, 75, 80],
        unit: 'mib_per_second',
        higherIsBetter: true,
      ),
    ]).single;

    expect(comparison.currentDeltaPercent, closeTo(-28.57, 0.01));
    expect(comparison.verdict, 'regression');
  });

  test('keeps immaterial movement at parity', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'http.steady', <num>[100, 100, 100]),
      _metric('current', 'http.steady', <num>[108, 108, 108]),
    ]).single;

    expect(comparison.verdict, 'parity');
  });

  test('zero-baseline event-loop jitter stays JSON-safe and immaterial', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'http.steady.event_loop_lag', <num>[0, 0, 0]),
      _metric('current', 'http.steady.event_loop_lag', <num>[0, 450, 900]),
    ]).single;

    expect(comparison.currentDeltaPercent, isNull);
    expect(comparison.verdict, 'parity');
    expect(comparison.toJson()['currentDeltaPercent'], isNull);
  });

  test('advisory scenarios never become gate verdicts', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'http.first_path', <num>[
        100,
        100,
        100,
      ], advisoryOnly: true),
      _metric('current', 'http.first_path', <num>[
        10000,
        10000,
        10000,
      ], advisoryOnly: true),
    ]).single;

    expect(comparison.advisoryOnly, isTrue);
    expect(comparison.verdict, 'advisory');
  });
}

Map<String, Object?> _metric(
  String target,
  String scenario,
  List<num> samples, {
  String unit = 'microseconds',
  bool higherIsBetter = false,
  bool advisoryOnly = false,
}) => <String, Object?>{
  'kind': 'metric',
  'target': target,
  'scenario': scenario,
  'unit': unit,
  'higherIsBetter': higherIsBetter,
  'advisoryOnly': advisoryOnly,
  'samples': samples,
};
