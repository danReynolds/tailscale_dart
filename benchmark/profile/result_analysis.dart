/// Aggregated release-versus-current result for one benchmark scenario.
final class PerfComparison {
  const PerfComparison({
    required this.scenario,
    required this.unit,
    required this.higherIsBetter,
    required this.baselineP50,
    required this.baselineP95,
    required this.currentP50,
    required this.currentP95,
    required this.currentDeltaPercent,
    required this.advisoryOnly,
    required this.verdict,
    required this.baselineSamples,
    required this.currentSamples,
  });

  final String scenario;
  final String unit;
  final bool higherIsBetter;
  final double baselineP50;
  final double baselineP95;
  final double currentP50;
  final double currentP95;

  /// Raw current-versus-baseline delta. Positive means numerically larger;
  /// whether that is good depends on [higherIsBetter].
  final double? currentDeltaPercent;
  final bool advisoryOnly;
  final String verdict;
  final List<double> baselineSamples;
  final List<double> currentSamples;

  Map<String, Object?> toJson() => <String, Object?>{
    'scenario': scenario,
    'unit': unit,
    'higherIsBetter': higherIsBetter,
    'baseline': <String, Object?>{
      'p50': baselineP50,
      'p95': baselineP95,
      'samples': baselineSamples,
    },
    'current': <String, Object?>{
      'p50': currentP50,
      'p95': currentP95,
      'samples': currentSamples,
    },
    'currentDeltaPercent': currentDeltaPercent,
    'advisoryOnly': advisoryOnly,
    'verdict': verdict,
  };
}

double perfPercentile(List<double> values, double percentile) {
  if (values.isEmpty) throw ArgumentError('values must not be empty');
  if (percentile < 0 || percentile > 1) {
    throw RangeError.range(percentile, 0, 1, 'percentile');
  }
  final sorted = List<double>.of(values)..sort();
  final index = ((sorted.length - 1) * percentile).round();
  return sorted[index];
}

List<PerfComparison> summarizePerfRecords(
  List<Map<String, Object?>> records, {
  String baselineTarget = 'release',
  String currentTarget = 'current',
  double materialityPercent = 15,
}) {
  final groups = <String, _MetricGroup>{};
  for (final record in records) {
    if (record['kind'] != 'metric') continue;
    final target = record['target'];
    final scenario = record['scenario'];
    final unit = record['unit'];
    final higherIsBetter = record['higherIsBetter'];
    final advisoryOnly = record['advisoryOnly'] ?? false;
    final rawSamples = record['samples'];
    if (target is! String ||
        scenario is! String ||
        unit is! String ||
        higherIsBetter is! bool ||
        advisoryOnly is! bool ||
        rawSamples is! List) {
      throw FormatException('invalid metric record: $record');
    }
    final key = '$scenario\u0000$unit\u0000$higherIsBetter\u0000$advisoryOnly';
    final group = groups.putIfAbsent(
      key,
      () => _MetricGroup(
        scenario: scenario,
        unit: unit,
        higherIsBetter: higherIsBetter,
        advisoryOnly: advisoryOnly,
      ),
    );
    group.samplesByTarget
        .putIfAbsent(target, () => <double>[])
        .addAll(rawSamples.map((value) => (value as num).toDouble()));
  }

  final comparisons = <PerfComparison>[];
  for (final group in groups.values) {
    final baseline = group.samplesByTarget[baselineTarget];
    final current = group.samplesByTarget[currentTarget];
    if (baseline == null ||
        baseline.isEmpty ||
        current == null ||
        current.isEmpty) {
      continue;
    }
    final baselineP50 = perfPercentile(baseline, 0.50);
    final baselineP95 = perfPercentile(baseline, 0.95);
    final currentP50 = perfPercentile(current, 0.50);
    final currentP95 = perfPercentile(current, 0.95);
    final useP95 = group.scenario.endsWith('.event_loop_lag');
    final baselineBasis = useP95 ? baselineP95 : baselineP50;
    final currentBasis = useP95 ? currentP95 : currentP50;
    final delta = baselineBasis == 0
        ? null
        : ((currentBasis / baselineBasis) - 1) * 100;
    final numericDirection = currentBasis.compareTo(baselineBasis);
    final regressionDirection = group.higherIsBetter
        ? -numericDirection
        : numericDirection;
    final absoluteDelta = (currentBasis - baselineBasis).abs();
    final absoluteFloor = switch (group.unit) {
      'microseconds' when useP95 => 1000.0,
      'microseconds' => 100.0,
      'bytes' => 5.0 * 1024 * 1024,
      _ => 0.0,
    };
    final materiallyDifferent =
        absoluteDelta > absoluteFloor &&
        (delta == null || delta.abs() > materialityPercent);
    final verdict = group.advisoryOnly
        ? 'advisory'
        : !materiallyDifferent || regressionDirection == 0
        ? 'parity'
        : regressionDirection > 0
        ? 'regression'
        : 'improvement';
    comparisons.add(
      PerfComparison(
        scenario: group.scenario,
        unit: group.unit,
        higherIsBetter: group.higherIsBetter,
        baselineP50: baselineP50,
        baselineP95: baselineP95,
        currentP50: currentP50,
        currentP95: currentP95,
        currentDeltaPercent: delta,
        advisoryOnly: group.advisoryOnly,
        verdict: verdict,
        baselineSamples: List<double>.unmodifiable(baseline),
        currentSamples: List<double>.unmodifiable(current),
      ),
    );
  }
  comparisons.sort((left, right) => left.scenario.compareTo(right.scenario));
  return comparisons;
}

final class _MetricGroup {
  _MetricGroup({
    required this.scenario,
    required this.unit,
    required this.higherIsBetter,
    required this.advisoryOnly,
  });

  final String scenario;
  final String unit;
  final bool higherIsBetter;
  final bool advisoryOnly;
  final Map<String, List<double>> samplesByTarget = <String, List<double>>{};
}
