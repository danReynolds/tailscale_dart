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
    required this.pairedTrials,
    required this.currentWins,
    required this.currentLosses,
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
  final int pairedTrials;
  final int currentWins;
  final int currentLosses;
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
    'pairedTrials': pairedTrials,
    'currentWins': currentWins,
    'currentLosses': currentLosses,
    'verdict': verdict,
  };
}

double perfPercentile(List<double> values, double percentile) {
  if (values.isEmpty) throw ArgumentError('values must not be empty');
  if (percentile < 0 || percentile > 1) {
    throw RangeError.range(percentile, 0, 1, 'percentile');
  }
  final sorted = List<double>.of(values)..sort();
  final index = percentile == 0 ? 0 : (sorted.length * percentile).ceil() - 1;
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
    final trial = record['trial'] ?? 0;
    final rawSamples = record['samples'];
    if (target is! String ||
        scenario is! String ||
        unit is! String ||
        higherIsBetter is! bool ||
        advisoryOnly is! bool ||
        trial is! int ||
        trial <= 0 ||
        rawSamples is! List ||
        rawSamples.isEmpty ||
        rawSamples.any((value) => value is! num || !value.isFinite)) {
      throw FormatException('invalid metric record: $record');
    }
    final group = groups.putIfAbsent(
      scenario,
      () => _MetricGroup(
        scenario: scenario,
        unit: unit,
        higherIsBetter: higherIsBetter,
        advisoryOnly: advisoryOnly,
      ),
    );
    if (group.unit != unit ||
        group.higherIsBetter != higherIsBetter ||
        group.advisoryOnly != advisoryOnly) {
      throw FormatException('metric contract changed for $scenario');
    }
    group.samplesByTarget
        .putIfAbsent(target, () => <double>[])
        .addAll(rawSamples.map((value) => (value as num).toDouble()));
    group.samplesByTargetAndTrial
        .putIfAbsent(target, () => <int, List<double>>{})
        .putIfAbsent(trial, () => <double>[])
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
      throw FormatException(
        '${group.scenario} is missing $baselineTarget or $currentTarget data',
      );
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
    final baselineTrials =
        group.samplesByTargetAndTrial[baselineTarget] ??
        const <int, List<double>>{};
    final currentTrials =
        group.samplesByTargetAndTrial[currentTarget] ??
        const <int, List<double>>{};
    if (baselineTrials.length != currentTrials.length ||
        baselineTrials.keys.any((trial) => !currentTrials.containsKey(trial))) {
      throw FormatException('${group.scenario} has unpaired trials');
    }
    final pairedTrialIds = baselineTrials.keys.toList()..sort();
    var currentWins = 0;
    var currentLosses = 0;
    for (final trial in pairedTrialIds) {
      final baselineTrial = perfPercentile(
        baselineTrials[trial]!,
        useP95 ? 0.95 : 0.50,
      );
      final currentTrial = perfPercentile(
        currentTrials[trial]!,
        useP95 ? 0.95 : 0.50,
      );
      final numericTrialDirection = currentTrial.compareTo(baselineTrial);
      final regressionTrialDirection = group.higherIsBetter
          ? -numericTrialDirection
          : numericTrialDirection;
      if (regressionTrialDirection > 0) currentLosses++;
      if (regressionTrialDirection < 0) currentWins++;
    }
    final enoughTrials = pairedTrialIds.length >= 3;
    final requiredConsistentTrials = (pairedTrialIds.length * 0.8).ceil();
    final consistentRegression = currentLosses >= requiredConsistentTrials;
    final consistentImprovement = currentWins >= requiredConsistentTrials;
    final verdict = group.advisoryOnly || !enoughTrials
        ? 'advisory'
        : !materiallyDifferent || regressionDirection == 0
        ? 'parity'
        : regressionDirection > 0 && consistentRegression
        ? 'regression'
        : regressionDirection < 0 && consistentImprovement
        ? 'improvement'
        : 'inconclusive';
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
        pairedTrials: pairedTrialIds.length,
        currentWins: currentWins,
        currentLosses: currentLosses,
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
  final Map<String, Map<int, List<double>>> samplesByTargetAndTrial =
      <String, Map<int, List<double>>>{};
}
