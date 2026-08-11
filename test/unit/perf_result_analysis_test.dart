import 'package:test/test.dart';

import '../../benchmark/profile/result_analysis.dart';

void main() {
  test('perfPercentile uses the nearest-rank sample', () {
    expect(perfPercentile(<double>[9, 1, 5, 3, 7], 0.50), 5);
    expect(perfPercentile(<double>[9, 1, 5, 3, 7], 0.95), 9);
    expect(perfPercentile(<double>[6, 1, 5, 2, 4, 3], 0.50), 3);
    expect(perfPercentile(<double>[6, 1, 5, 2, 4, 3], 0), 1);
    expect(perfPercentile(<double>[6, 1, 5, 2, 4, 3], 1), 6);
  });

  test('summarizes samples across trials', () {
    final comparisons = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'control.status', <num>[1000, 1200], trial: 1),
      _metric('release', 'control.status', <num>[1100, 1300], trial: 2),
      _metric('release', 'control.status', <num>[1050, 1250], trial: 3),
      _metric('current', 'control.status', <num>[700, 800], trial: 1),
      _metric('current', 'control.status', <num>[750, 850], trial: 2),
      _metric('current', 'control.status', <num>[725, 825], trial: 3),
    ]);

    expect(comparisons, hasLength(1));
    final result = comparisons.single;
    expect(result.baselineSamples, <double>[
      1000,
      1200,
      1100,
      1300,
      1050,
      1250,
    ]);
    expect(result.currentSamples, <double>[700, 800, 750, 850, 725, 825]);
    expect(result.baselineP50, 1100);
    expect(result.currentP50, 750);
    expect(result.pairedTrials, 3);
    expect(result.currentWins, 3);
    expect(result.currentLosses, 0);
    expect(result.verdict, 'improvement');
  });

  test('understands higher-is-better throughput', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      for (var trial = 1; trial <= 3; trial++)
        _metric(
          'release',
          'tcp.throughput',
          <num>[100, 105, 110],
          trial: trial,
          unit: 'mib_per_second',
          higherIsBetter: true,
        ),
      for (var trial = 1; trial <= 3; trial++)
        _metric(
          'current',
          'tcp.throughput',
          <num>[70, 75, 80],
          trial: trial,
          unit: 'mib_per_second',
          higherIsBetter: true,
        ),
    ]).single;

    expect(comparison.currentDeltaPercent, closeTo(-28.57, 0.01));
    expect(comparison.currentLosses, 3);
    expect(comparison.verdict, 'regression');
  });

  test('keeps immaterial movement at parity', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      for (var trial = 1; trial <= 3; trial++)
        _metric('release', 'http.steady', <num>[100, 100, 100], trial: trial),
      for (var trial = 1; trial <= 3; trial++)
        _metric('current', 'http.steady', <num>[108, 108, 108], trial: trial),
    ]).single;

    expect(comparison.verdict, 'parity');
  });

  test('zero-baseline event-loop jitter stays JSON-safe and immaterial', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      for (var trial = 1; trial <= 3; trial++)
        _metric('release', 'http.steady.event_loop_lag', <num>[
          0,
          0,
          0,
        ], trial: trial),
      for (var trial = 1; trial <= 3; trial++)
        _metric('current', 'http.steady.event_loop_lag', <num>[
          0,
          450,
          900,
        ], trial: trial),
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

  test('requires a consistent paired direction for a verdict', () {
    final comparisons = summarizePerfRecords(<Map<String, Object?>>[
      for (var trial = 1; trial <= 5; trial++)
        _metric(
          'release',
          'tcp.bulk',
          <num>[30],
          trial: trial,
          unit: 'mib_per_second',
          higherIsBetter: true,
        ),
      for (final entry in <int, num>{1: 60, 2: 20, 3: 60, 4: 20, 5: 20}.entries)
        _metric(
          'current',
          'tcp.bulk',
          <num>[entry.value],
          trial: entry.key,
          unit: 'mib_per_second',
          higherIsBetter: true,
        ),
    ]);

    final comparison = comparisons.single;
    expect(comparison.currentWins, 2);
    expect(comparison.currentLosses, 3);
    expect(comparison.verdict, 'inconclusive');
  });

  test('a one-trial quick run stays advisory', () {
    final comparison = summarizePerfRecords(<Map<String, Object?>>[
      _metric('release', 'control.status', <num>[1000], trial: 1),
      _metric('current', 'control.status', <num>[2000], trial: 1),
    ]).single;

    expect(comparison.advisoryOnly, isFalse);
    expect(comparison.pairedTrials, 1);
    expect(comparison.verdict, 'advisory');
  });

  test('rejects a metric contract mismatch between targets', () {
    expect(
      () => summarizePerfRecords(<Map<String, Object?>>[
        _metric('release', 'control.status', <num>[1000]),
        _metric('current', 'control.status', <num>[1000], unit: 'bytes'),
      ]),
      throwsFormatException,
    );
  });

  test('rejects missing paired trials', () {
    expect(
      () => summarizePerfRecords(<Map<String, Object?>>[
        for (var trial = 1; trial <= 3; trial++)
          _metric('release', 'control.status', <num>[1000], trial: trial),
        for (var trial = 1; trial <= 2; trial++)
          _metric('current', 'control.status', <num>[1000], trial: trial),
      ]),
      throwsFormatException,
    );
  });
}

Map<String, Object?> _metric(
  String target,
  String scenario,
  List<num> samples, {
  int trial = 1,
  String unit = 'microseconds',
  bool higherIsBetter = false,
  bool advisoryOnly = false,
}) => <String, Object?>{
  'kind': 'metric',
  'target': target,
  'scenario': scenario,
  'trial': trial,
  'unit': unit,
  'higherIsBetter': higherIsBetter,
  'advisoryOnly': advisoryOnly,
  'samples': samples,
};
