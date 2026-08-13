import 'dart:convert';
import 'dart:math' as math;

import 'package:tailscale_profile_harness/tailscale_profile_harness.dart';

const _capabilities = <(String, String, bool)>[
  ('overall', 'Overall', true),
  ('join', 'Join', true),
  ('discovery', 'Nodes', true),
  ('ping', 'Ping*', false),
  ('whois', 'WhoIs', true),
  ('httpGet', 'HTTP GET', true),
  ('httpPost', 'HTTP POST', true),
  ('tcpEcho', 'TCP', true),
  ('udpEcho', 'UDP', true),
  ('profile', 'Profile', false),
  ('restart', 'Restart', true),
];

const _qualificationCapabilities = <(String, String)>[
  ('ephemeralDataPlane', 'Ephemeral data plane'),
  ('persistentCustody', 'Persistent custody'),
  ('processDeathReconnect', 'Process-death reconnect'),
  ('localReset', 'Local reset'),
  ('profiling', 'Profiling'),
];

Map<String, Object?> buildSmokeRunArtifact({
  required List<Map<String, Object?>> runs,
  required Map<String, Object?> source,
  required Map<String, Object?> environment,
  required int profileSamples,
  required String profileContext,
  DateTime? generatedAt,
}) {
  return <String, Object?>{
    'schema': 3,
    'kind': 'tailscale-dart-device-smoke',
    'generatedAt': (generatedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'source': source,
    'environment': environment,
    'configuration': <String, Object?>{
      'controlPlane': 'local-headscale',
      'profileSamples': profileSamples,
      'profileContext': profileContext,
      'speedRunsPerDirection': 3,
      'speedTest': canonicalSpeedTestConfig.toJson(),
      'nativeTsnetRunsPerDirection': 3,
      'lanRunsPerDirection': 1,
      'lanSpeedTest': ordinaryLanControlConfig.toJson(),
    },
    'targets': [
      for (final run in runs)
        <String, Object?>{
          'target': run['target'],
          'status': run['skipped'] == true
              ? 'skip'
              : run['ok'] == true
              ? 'pass'
              : 'fail',
          if (run['device'] case final Map<String, Object?> device)
            'device': device,
          if (run['result'] case final Map<String, Object?> result) ...{
            if (result['durationMs'] is num) 'durationMs': result['durationMs'],
            'capabilities': smokeCapabilities(run),
            'qualification': smokeQualificationCapabilities(run),
            if (result['custody'] case final Map<String, Object?> custody)
              'custody': _custodySummary(custody),
            if (result['profile'] case final Map<String, Object?> profile)
              'profile': _profileSummary(
                profile,
                expectedSamples: profileSamples,
                profileRunMode:
                    environment['flutterRunMode'] as String? ?? 'profile',
              ),
          } else
            'capabilities': smokeCapabilities(run),
          'qualification': smokeQualificationCapabilities(run),
        },
    ],
  };
}

List<Map<String, Object?>> smokeQualificationCapabilities(
  Map<String, Object?> run,
) {
  final skipped = run['skipped'] == true;
  final result = run['result'] as Map<String, Object?>?;
  if (result == null) {
    return [
      for (final definition in _qualificationCapabilities)
        <String, Object?>{
          'id': definition.$1,
          'label': definition.$2,
          'status': skipped ? 'skip' : 'notRun',
        },
    ];
  }

  final mode = result['mode'] as String? ?? 'ephemeral';
  final custody = result['custody'] as Map<String, Object?>?;
  final profile = result['profile'] as Map<String, Object?>?;
  String custodyStatus(String key) => custody?[key] as String? ?? 'notRun';
  return [
    _qualificationCapability(
      'ephemeralDataPlane',
      mode == 'ephemeral'
          ? result['ok'] == true
                ? 'pass'
                : 'fail'
          : 'notRun',
    ),
    _qualificationCapability(
      'persistentCustody',
      mode == 'persistentCustody'
          ? custodyStatus('persistentCustody')
          : 'notRun',
    ),
    _qualificationCapability(
      'processDeathReconnect',
      mode == 'persistentCustody'
          ? custodyStatus('processDeathReconnect')
          : 'notRun',
    ),
    _qualificationCapability(
      'localReset',
      mode == 'persistentCustody' ? custodyStatus('localReset') : 'notRun',
    ),
    _qualificationCapability(
      'profiling',
      profile == null
          ? 'notRun'
          : profile['status'] == 'complete'
          ? 'pass'
          : profile['status'] == 'error'
          ? 'fail'
          : 'warn',
    ),
  ];
}

List<Map<String, Object?>> smokeCapabilities(Map<String, Object?> run) {
  final skipped = run['skipped'] == true;
  final result = run['result'] as Map<String, Object?>?;
  if (result == null) {
    return [
      for (final definition in _capabilities)
        <String, Object?>{
          'id': definition.$1,
          'label': definition.$2,
          'required': definition.$3,
          'status': skipped ? 'skip' : 'notRun',
        },
    ];
  }

  final report = result['report'] as Map<String, Object?>?;
  final restart = result['restart'] as Map<String, Object?>?;
  final profile = result['profile'] as Map<String, Object?>?;
  return [
    _capability('overall', run['ok'] == true ? 'pass' : 'fail'),
    _capability(
      'join',
      _nonEmptyString(result['localIp']) && report != null ? 'pass' : 'fail',
    ),
    _capability(
      'discovery',
      (result['nodesSeen'] as num? ?? 0) > 0 ? 'pass' : 'fail',
    ),
    _probeCapability(report, 'ping', required: false),
    _probeCapability(report, 'whois'),
    _probeCapability(report, 'httpGet'),
    _probeCapability(report, 'httpPost'),
    _probeCapability(report, 'tcpEcho'),
    _probeCapability(report, 'udpEcho'),
    _capability(
      'profile',
      profile == null
          ? 'notRun'
          : profile['status'] == 'complete'
          ? 'pass'
          : profile['status'] == 'error'
          ? 'fail'
          : 'warn',
    ),
    _capability('restart', restart?['ok'] == true ? 'pass' : 'fail'),
  ];
}

String renderSmokeCapabilityMatrix(List<Map<String, Object?>> runs) {
  final headers = <String>['Target', ..._capabilities.map((value) => value.$2)];
  final rows = <List<String>>[
    headers,
    for (final run in runs)
      <String>[
        run['target'] as String? ?? 'unknown',
        for (final capability in smokeCapabilities(run))
          _statusLabel(capability['status'] as String),
      ],
  ];
  final widths = <int>[
    for (var column = 0; column < headers.length; column++)
      rows.map((row) => row[column].length).reduce(math.max),
  ];
  final lines = <String>[];
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final row = rows[rowIndex];
    lines.add(
      [
        for (var column = 0; column < row.length; column++)
          row[column].padRight(widths[column]),
      ].join(' | '),
    );
    if (rowIndex == 0) {
      lines.add(
        [
          for (final width in widths) List.filled(width, '-').join(),
        ].join('-|-'),
      );
    }
  }
  lines.add('* Ping is diagnostic and does not determine the smoke verdict.');
  return lines.join('\n');
}

String renderSmokeQualificationMatrix(List<Map<String, Object?>> runs) {
  final headers = <String>[
    'Target',
    ..._qualificationCapabilities.map((value) => value.$2),
  ];
  final rows = <List<String>>[
    headers,
    for (final run in runs)
      <String>[
        run['target'] as String? ?? 'unknown',
        for (final capability in smokeQualificationCapabilities(run))
          _statusLabel(capability['status'] as String),
      ],
  ];
  final widths = <int>[
    for (var column = 0; column < headers.length; column++)
      rows.map((row) => row[column].length).reduce(math.max),
  ];
  final lines = <String>[];
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final row = rows[rowIndex];
    lines.add(
      [
        for (var column = 0; column < row.length; column++)
          row[column].padRight(widths[column]),
      ].join(' | '),
    );
    if (rowIndex == 0) {
      lines.add(
        [
          for (final width in widths) List.filled(width, '-').join(),
        ].join('-|-'),
      );
    }
  }
  lines.add('NOT RUN is distinct from PASS and does not qualify that lane.');
  return lines.join('\n');
}

String renderSmokeRunMarkdown(Map<String, Object?> artifact) {
  final source = artifact['source'] as Map<String, Object?>? ?? const {};
  final environment =
      artifact['environment'] as Map<String, Object?>? ?? const {};
  final targets = (artifact['targets'] as List? ?? const [])
      .cast<Map<String, Object?>>();
  final buffer = StringBuffer()
    ..writeln('# Device correctness and network profile')
    ..writeln()
    ..writeln('- Generated: `${artifact['generatedAt']}`')
    ..writeln('- Package: `tailscale ${source['version'] ?? 'unknown'}`')
    ..writeln('- Commit: `${source['commit'] ?? 'unknown'}`')
    ..writeln('- Dirty checkout: `${source['dirty'] ?? 'unknown'}`')
    ..writeln('- Flutter: `${environment['flutter'] ?? 'unknown'}`')
    ..writeln('- Dart: `${environment['dart'] ?? 'unknown'}`')
    ..writeln()
    ..writeln('## Platform qualification')
    ..writeln()
    ..writeln(
      '| Target | ${_qualificationCapabilities.map((value) => value.$2).join(' | ')} |',
    )
    ..writeln(
      '| --- | ${_qualificationCapabilities.map((_) => '---').join(' | ')} |',
    );
  for (final target in targets) {
    final qualification = (target['qualification'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    buffer.writeln(
      '| ${target['target']} | ${qualification.map((value) => _statusLabel(value['status'] as String)).join(' | ')} |',
    );
  }
  buffer
    ..writeln()
    ..writeln(
      '`NOT RUN` is distinct from `PASS` and does not qualify that lane.',
    )
    ..writeln()
    ..writeln('## Correctness matrix')
    ..writeln()
    ..writeln(
      '| Target | ${_capabilities.map((value) => value.$2).join(' | ')} |',
    )
    ..writeln('| --- | ${_capabilities.map((_) => '---').join(' | ')} |');
  for (final target in targets) {
    final capabilities = (target['capabilities'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    buffer.writeln(
      '| ${target['target']} | ${capabilities.map((value) => _statusLabel(value['status'] as String)).join(' | ')} |',
    );
  }
  buffer
    ..writeln()
    ..writeln(
      '\\* Ping is diagnostic and does not determine the smoke verdict.',
    );

  for (final target in targets) {
    if (target['custody'] case final Map<String, Object?> custody) {
      buffer
        ..writeln()
        ..writeln('## ${target['target']} persistent custody')
        ..writeln()
        ..writeln('- Backend: `${custody['scheme'] ?? 'unknown'}`')
        ..writeln('- Protection: `${custody['securityLevel'] ?? 'unknown'}`')
        ..writeln(
          '- Persistent backend: `${custody['backendPersistent'] ?? 'unknown'}`',
        )
        ..writeln(
          '- DEK present before reconnect: `${custody['dekBeforeReconnect'] ?? 'unknown'}`',
        )
        ..writeln(
          '- Identity preserved: `${custody['identityPreserved'] ?? 'unknown'}`',
        )
        ..writeln(
          '- Data plane after reconnect: `${custody['dataPlaneAfterReconnect'] ?? 'unknown'}`',
        )
        ..writeln(
          '- DEK absent after reset: `${custody['dekAbsentAfterReset'] ?? 'unknown'}`',
        )
        ..writeln(
          '- State subtree removed: `${custody['stateSubtreeRemoved'] ?? 'unknown'}`',
        );
    }
    final profile = target['profile'] as Map<String, Object?>?;
    if (profile == null) continue;
    final device = target['device'] as Map<String, Object?>? ?? const {};
    buffer
      ..writeln()
      ..writeln('## ${target['target']} network profile')
      ..writeln()
      ..writeln(
        '- Device: `${device['targetPlatform'] ?? target['target']}`; '
        '${device['deviceClass'] ?? 'unknown'}',
      )
      ..writeln('- OS/runtime: `${device['sdk'] ?? 'unknown'}`')
      ..writeln(
        '- Flutter run mode: `${environment['flutterRunMode'] ?? 'unknown'}`',
      )
      ..writeln(
        '- Flutter launch mode: `${environment['flutterLaunchMode'] ?? 'unknown'}`',
      )
      ..writeln(
        '- Samples: `${profile['completedSamples']}/${profile['expectedSamples']}`',
      )
      ..writeln('- Collection: `${profile['status']}`')
      ..writeln('- Comparison eligible: `${profile['comparisonEligible']}`');
    if (profile['comparisonIneligibleReason'] case final String reason) {
      buffer.writeln('- Comparison note: `$reason`');
    }
    final paths = profile['networkPaths'] as Map<String, Object?>? ?? const {};
    if (paths.isNotEmpty) {
      buffer.writeln(
        '- Tailscale paths: `${paths.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}`',
      );
    }
    buffer
      ..writeln()
      ..writeln('| API metric | Samples | p50 | p95 | Mean |')
      ..writeln('| --- | ---: | ---: | ---: | ---: |');
    final metrics = (profile['metrics'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    for (final metric in metrics) {
      final unit = metric['unit'] as String;
      buffer.writeln(
        '| ${metric['label']} | ${metric['sampleCount']} | '
        '${_formatMetric(metric['p50'] as num, unit)} | '
        '${_formatMetric(metric['p95'] as num, unit)} | '
        '${_formatMetric(metric['mean'] as num, unit)} |',
      );
    }
    final throughput = (profile['throughput'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    if (throughput.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('| Dart public API over Tailscale | Runs | Median | Range |')
        ..writeln('| --- | ---: | ---: | ---: |');
      for (final value in throughput) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['median'] as num, 'MiB/s')} | '
          '${_formatMetric(value['min'] as num, 'MiB/s')} - '
          '${_formatMetric(value['max'] as num, 'MiB/s')} |',
        );
      }
    }
    final writeCompletion = (profile['writeCompletion'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    if (writeCompletion.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          '| Tailscale sender write completion | Runs | Median p50 | Median p95 | Median p99 |',
        )
        ..writeln('| --- | ---: | ---: | ---: | ---: |');
      for (final value in writeCompletion) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['medianP50Us'] as num, 'microseconds')} | '
          '${_formatMetric(value['medianP95Us'] as num, 'microseconds')} | '
          '${_formatMetric(value['medianP99Us'] as num, 'microseconds')} |',
        );
      }
    }
    final nativeTsnetThroughput =
        (profile['nativeTsnetThroughput'] as List? ?? const [])
            .cast<Map<String, Object?>>();
    if (nativeTsnetThroughput.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          'The direct control bypasses the Dart bridge on the device only; '
          'both lanes use the same remote Dart peer.',
        )
        ..writeln()
        ..writeln(
          '| Device-side direct tsnet control | Runs | Median | Range |',
        )
        ..writeln('| --- | ---: | ---: | ---: |');
      for (final value in nativeTsnetThroughput) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['median'] as num, 'MiB/s')} | '
          '${_formatMetric(value['min'] as num, 'MiB/s')} - '
          '${_formatMetric(value['max'] as num, 'MiB/s')} |',
        );
      }
    }
    final dartToNative = (profile['dartApiToNativeTsnet'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    if (dartToNative.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('| Dart API / direct tsnet client | Pairs | Median | Range |')
        ..writeln('| --- | ---: | ---: | ---: |');
      for (final value in dartToNative) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['medianPercent'] as num, 'percent')} | '
          '${_formatMetric(value['minPercent'] as num, 'percent')} - '
          '${_formatMetric(value['maxPercent'] as num, 'percent')} |',
        );
      }
    }
    final lanThroughput = (profile['lanThroughput'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    if (lanThroughput.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('| Ordinary LAN control | Runs | Median | Range |')
        ..writeln('| --- | ---: | ---: | ---: |');
      for (final value in lanThroughput) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['median'] as num, 'MiB/s')} | '
          '${_formatMetric(value['min'] as num, 'MiB/s')} - '
          '${_formatMetric(value['max'] as num, 'MiB/s')} |',
        );
      }
    }
    final lanWriteCompletion =
        (profile['lanWriteCompletion'] as List? ?? const [])
            .cast<Map<String, Object?>>();
    if (lanWriteCompletion.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          '| LAN sender write completion | Runs | Median p50 | Median p95 | Median p99 |',
        )
        ..writeln('| --- | ---: | ---: | ---: | ---: |');
      for (final value in lanWriteCompletion) {
        buffer.writeln(
          '| ${value['direction']} | ${value['sampleCount']} | '
          '${_formatMetric(value['medianP50Us'] as num, 'microseconds')} | '
          '${_formatMetric(value['medianP95Us'] as num, 'microseconds')} | '
          '${_formatMetric(value['medianP99Us'] as num, 'microseconds')} |',
        );
      }
    }
  }

  buffer
    ..writeln()
    ..writeln(
      'Performance measurements are advisory. The JSON report retains every raw '
      'sample for like-for-like historical comparisons.',
    );
  return buffer.toString();
}

Map<String, Object?> _custodySummary(Map<String, Object?> custody) => {
  for (final key in const [
    'persistentCustody',
    'processDeathReconnect',
    'localReset',
    'scheme',
    'securityLevel',
    'backendPersistent',
    'dekBeforeReconnect',
    'identityPreserved',
    'dataPlaneAfterReconnect',
    'dekAbsentAfterReset',
    'stateSubtreeRemoved',
  ])
    if (custody.containsKey(key)) key: custody[key],
};

Map<String, Object?> _profileSummary(
  Map<String, Object?> profile, {
  required int expectedSamples,
  required String profileRunMode,
}) {
  final reports = (profile['reports'] as List? ?? const [])
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
  final speedTests = (profile['speedTests'] as List? ?? const [])
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
  final nativeTsnetSpeedTests =
      (profile['nativeTsnetSpeedTests'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .toList(growable: false);
  final lanSpeedTests = (profile['lanSpeedTests'] as List? ?? const [])
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
  final metrics = <Map<String, Object?>>[];
  const probeMetrics = <String, String>{
    'ping': 'Ping API round trip',
    'whois': 'WhoIs',
    'httpGet': 'HTTP GET',
    'httpPost': 'HTTP POST',
    'tcpEcho': 'TCP echo',
    'udpEcho': 'UDP echo',
  };
  for (final entry in probeMetrics.entries) {
    final samples = _probeSamples(reports, entry.key, 'durationUs');
    if (samples.isNotEmpty) {
      metrics.add(
        _metric('${entry.key}.roundTrip', entry.value, 'microseconds', samples),
      );
    }
  }

  final networkRtt = _probeSamples(reports, 'ping', 'networkLatencyUs');
  if (networkRtt.isNotEmpty) {
    metrics.add(
      _metric(
        'ping.networkRtt',
        'Ping network RTT',
        'microseconds',
        networkRtt,
      ),
    );
  }
  final paths = <String, int>{};
  for (final report in reports) {
    final ping = _probeResult(report, 'ping');
    final path = ping?['networkPath'];
    if (ping?['ok'] == true && path is String && path.isNotEmpty) {
      paths.update(path, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  metrics.sort(
    (left, right) => (left['id'] as String).compareTo(right['id'] as String),
  );
  final dartSummary = _wrappedSpeedTestSummary(speedTests);
  final nativeSummary = _wrappedSpeedTestSummary(nativeTsnetSpeedTests);
  final lanThroughput = <Map<String, Object?>>[];
  final eligibleLanResults = <Map<String, Object?>>[];
  for (final direction in SpeedTestDirection.values) {
    final samples = <double>[];
    for (final result in lanSpeedTests) {
      if (!_eligibleLanSpeedTest(result, direction)) continue;
      final rate = result['mibPerSecond'];
      if (rate is num && rate.isFinite) {
        samples.add(rate.toDouble());
        eligibleLanResults.add(result);
      }
    }
    if (samples.isEmpty) continue;
    final sorted = List<double>.of(samples)..sort();
    lanThroughput.add(<String, Object?>{
      'direction': direction.name,
      'sampleCount': samples.length,
      'median': _percentile(samples, 0.50),
      'min': sorted.first,
      'max': sorted.last,
      'samples': samples,
    });
  }
  final expectedSpeedTests = SpeedTestDirection.values.length * 3;
  final expectedLanSpeedTests = SpeedTestDirection.values.length;
  final tailscaleComparisonEligible =
      speedTests.length == expectedSpeedTests &&
      SpeedTestDirection.values.every(
        (direction) =>
            speedTests
                .where((value) => _eligibleSpeedTest(value, direction))
                .length ==
            3,
      );
  final nativeTsnetComparisonEligible =
      nativeTsnetSpeedTests.length == expectedSpeedTests &&
      SpeedTestDirection.values.every(
        (direction) =>
            nativeTsnetSpeedTests
                .where((value) => _eligibleSpeedTest(value, direction))
                .length ==
            3,
      );
  final lanControlComplete =
      lanSpeedTests.length == expectedLanSpeedTests &&
      SpeedTestDirection.values.every(
        (direction) =>
            lanSpeedTests
                .where((value) => _eligibleLanSpeedTest(value, direction))
                .length ==
            1,
      );
  final collectionComplete =
      tailscaleComparisonEligible &&
      nativeTsnetComparisonEligible &&
      lanControlComplete;
  final comparisonEligible = collectionComplete && profileRunMode == 'profile';
  final smallSamplesComplete =
      reports.length == expectedSamples &&
      reports.every((value) => value['requiredOk'] == true);
  return <String, Object?>{
    'status': profile['status'] ?? 'invalid',
    'valid':
        profile['status'] == 'complete' &&
        smallSamplesComplete &&
        collectionComplete,
    'comparisonEligible': comparisonEligible,
    if (!comparisonEligible)
      'comparisonIneligibleReason': profileRunMode != 'profile'
          ? 'Flutter $profileRunMode mode is diagnostic only'
          : 'profile collection was incomplete',
    'context': profile['context'] ?? 'primary',
    'expectedSamples': expectedSamples,
    'completedSamples': reports.length,
    'completedSpeedTests': speedTests.length,
    'expectedSpeedTests': expectedSpeedTests,
    'completedNativeTsnetSpeedTests': nativeTsnetSpeedTests.length,
    'expectedNativeTsnetSpeedTests': expectedSpeedTests,
    'nativeTsnetControlComplete': nativeTsnetComparisonEligible,
    'completedLanSpeedTests': lanSpeedTests.length,
    'expectedLanSpeedTests': expectedLanSpeedTests,
    'lanControlComplete': lanControlComplete,
    'networkPaths': paths,
    'advisoryOnly': true,
    'metrics': metrics,
    'throughput': dartSummary.throughput,
    'writeCompletion': _writeCompletionSummary(dartSummary.results),
    'nativeTsnetThroughput': nativeSummary.throughput,
    'nativeTsnetWriteCompletion': _writeCompletionSummary(
      nativeSummary.results,
    ),
    'dartApiToNativeTsnet': _pairedSpeedRatios(
      speedTests,
      nativeTsnetSpeedTests,
    ),
    'lanThroughput': lanThroughput,
    'lanWriteCompletion': _writeCompletionSummary(eligibleLanResults),
    'raw': <String, Object?>{
      'apiReports': [for (final report in reports) _sanitizeReport(report)],
      'speedTests': speedTests,
      'nativeTsnetSpeedTests': nativeTsnetSpeedTests,
      'lanSpeedTests': lanSpeedTests,
    },
  };
}

({List<Map<String, Object?>> throughput, List<Map<String, Object?>> results})
_wrappedSpeedTestSummary(List<Map<String, Object?>> speedTests) {
  final throughput = <Map<String, Object?>>[];
  final results = <Map<String, Object?>>[];
  for (final direction in SpeedTestDirection.values) {
    final samples = <double>[];
    for (final speedTest in speedTests) {
      final result = speedTest['result'];
      if (!_eligibleSpeedTest(speedTest, direction) ||
          result is! Map<String, Object?>) {
        continue;
      }
      final rate = result['mibPerSecond'];
      if (rate is num && rate.isFinite) {
        samples.add(rate.toDouble());
        results.add(result);
      }
    }
    if (samples.isEmpty) continue;
    final sorted = List<double>.of(samples)..sort();
    throughput.add(<String, Object?>{
      'direction': direction.name,
      'sampleCount': samples.length,
      'median': _percentile(samples, 0.50),
      'min': sorted.first,
      'max': sorted.last,
      'samples': samples,
    });
  }
  return (throughput: throughput, results: results);
}

List<Map<String, Object?>> _pairedSpeedRatios(
  List<Map<String, Object?>> dartTests,
  List<Map<String, Object?>> nativeTests,
) {
  final summaries = <Map<String, Object?>>[];
  for (final direction in SpeedTestDirection.values) {
    final dartDirectionTests = dartTests
        .where((value) => _speedTestDirection(value) == direction)
        .toList(growable: false);
    final nativeDirectionTests = nativeTests
        .where((value) => _speedTestDirection(value) == direction)
        .toList(growable: false);
    if (dartDirectionTests.length != nativeDirectionTests.length) continue;
    final ratios = <double>[];
    for (var index = 0; index < dartDirectionTests.length; index++) {
      final dartRate = _eligibleRate(dartDirectionTests[index], direction);
      final nativeRate = _eligibleRate(nativeDirectionTests[index], direction);
      if (dartRate != null && nativeRate != null) {
        ratios.add(dartRate / nativeRate * 100);
      }
    }
    if (ratios.isEmpty) continue;
    final sorted = List<double>.of(ratios)..sort();
    summaries.add(<String, Object?>{
      'direction': direction.name,
      'sampleCount': ratios.length,
      'medianPercent': _percentile(ratios, 0.50),
      'minPercent': sorted.first,
      'maxPercent': sorted.last,
      'samplesPercent': ratios,
    });
  }
  return summaries;
}

SpeedTestDirection? _speedTestDirection(Map<String, Object?> speedTest) {
  final result = speedTest['result'];
  if (result is! Map<String, Object?>) return null;
  for (final direction in SpeedTestDirection.values) {
    if (direction.name == result['direction']) return direction;
  }
  return null;
}

double? _eligibleRate(
  Map<String, Object?> speedTest,
  SpeedTestDirection direction,
) {
  if (!_eligibleSpeedTest(speedTest, direction)) return null;
  final result = speedTest['result'] as Map<String, Object?>;
  final rate = result['mibPerSecond'];
  return rate is num && rate.isFinite && rate > 0 ? rate.toDouble() : null;
}

bool _eligibleLanSpeedTest(
  Map<String, Object?> result,
  SpeedTestDirection direction,
) =>
    result['valid'] == true &&
    result['direction'] == direction.name &&
    jsonEncode(result['config']) ==
        jsonEncode(ordinaryLanControlConfig.toJson()) &&
    result['writeCompletion'] is Map<String, Object?>;

List<Map<String, Object?>> _writeCompletionSummary(
  List<Map<String, Object?>> results,
) {
  final summaries = <Map<String, Object?>>[];
  for (final direction in SpeedTestDirection.values) {
    final p50 = <double>[];
    final p95 = <double>[];
    final p99 = <double>[];
    for (final result in results) {
      if (result['direction'] != direction.name) continue;
      final writeCompletion = result['writeCompletion'];
      if (writeCompletion is! Map<String, Object?>) continue;
      final p50Us = writeCompletion['p50Us'];
      final p95Us = writeCompletion['p95Us'];
      final p99Us = writeCompletion['p99Us'];
      if (p50Us is num && p95Us is num && p99Us is num) {
        p50.add(p50Us.toDouble());
        p95.add(p95Us.toDouble());
        p99.add(p99Us.toDouble());
      }
    }
    if (p50.isEmpty) continue;
    summaries.add(<String, Object?>{
      'direction': direction.name,
      'sampleCount': p50.length,
      'medianP50Us': _percentile(p50, 0.50),
      'medianP95Us': _percentile(p95, 0.50),
      'medianP99Us': _percentile(p99, 0.50),
      'p50SamplesUs': p50,
      'p95SamplesUs': p95,
      'p99SamplesUs': p99,
    });
  }
  return summaries;
}

bool _eligibleSpeedTest(
  Map<String, Object?> speedTest,
  SpeedTestDirection direction,
) {
  final result = speedTest['result'];
  final before = speedTest['pathBefore'];
  final after = speedTest['pathAfter'];
  if (speedTest['comparisonEligible'] != true ||
      result is! Map<String, Object?> ||
      before is! Map<String, Object?> ||
      after is! Map<String, Object?> ||
      result['valid'] != true ||
      result['direction'] != direction.name ||
      jsonEncode(result['config']) !=
          jsonEncode(canonicalSpeedTestConfig.toJson())) {
    return false;
  }
  final beforePath = before['networkPath'];
  return beforePath is String &&
      beforePath != 'unknown' &&
      beforePath == after['networkPath'];
}

Map<String, Object?> _metric(
  String id,
  String label,
  String unit,
  List<double> samples,
) {
  final total = samples.fold<double>(0, (sum, value) => sum + value);
  return <String, Object?>{
    'id': id,
    'label': label,
    'unit': unit,
    'advisoryOnly': true,
    'sampleCount': samples.length,
    'p50': _percentile(samples, 0.50),
    'p95': _percentile(samples, 0.95),
    'mean': total / samples.length,
    'samples': samples,
  };
}

Map<String, Object?> _sanitizeReport(
  Map<String, Object?> report,
) => <String, Object?>{
  'ok': report['ok'],
  'requiredOk': report['requiredOk'],
  'results': [
    for (final value in report['results'] as List? ?? const [])
      if (value is Map<String, Object?>)
        <String, Object?>{
          'kind': value['kind'],
          'ok': value['ok'],
          'durationUs': value['durationUs'],
          if (value['networkLatencyUs'] != null)
            'networkLatencyUs': value['networkLatencyUs'],
          if (value['networkPath'] != null) 'networkPath': value['networkPath'],
        },
  ],
};

List<double> _probeSamples(
  List<Map<String, Object?>> reports,
  String kind,
  String field,
) {
  final samples = <double>[];
  for (final report in reports) {
    final result = _probeResult(report, kind);
    final value = result?[field];
    if (result?['ok'] == true && value is num && value.isFinite) {
      samples.add(value.toDouble());
    }
  }
  return samples;
}

Map<String, Object?>? _probeResult(Map<String, Object?> report, String kind) {
  final results = report['results'];
  if (results is! List) return null;
  for (final value in results) {
    if (value is Map<String, Object?> && value['kind'] == kind) return value;
  }
  return null;
}

Map<String, Object?> _probeCapability(
  Map<String, Object?>? report,
  String kind, {
  bool required = true,
}) {
  final probe = report == null ? null : _probeResult(report, kind);
  final status = probe == null
      ? 'notRun'
      : probe['ok'] == true
      ? 'pass'
      : required
      ? 'fail'
      : 'warn';
  return _capability(kind, status, durationUs: probe?['durationUs'] as num?);
}

Map<String, Object?> _capability(String id, String status, {num? durationUs}) {
  final definition = _capabilities.firstWhere((value) => value.$1 == id);
  return <String, Object?>{
    'id': id,
    'label': definition.$2,
    'required': definition.$3,
    'status': status,
    'durationUs': ?durationUs,
  };
}

Map<String, Object?> _qualificationCapability(String id, String status) {
  final definition = _qualificationCapabilities.firstWhere(
    (value) => value.$1 == id,
  );
  return <String, Object?>{'id': id, 'label': definition.$2, 'status': status};
}

double _percentile(List<double> values, double percentile) {
  final sorted = List<double>.of(values)..sort();
  final index = (sorted.length * percentile).ceil() - 1;
  return sorted[index.clamp(0, sorted.length - 1).toInt()];
}

String _statusLabel(String status) => switch (status) {
  'pass' => 'PASS',
  'fail' => 'FAIL',
  'warn' => 'WARN',
  'skip' => 'SKIP',
  'notRun' => 'NOT RUN',
  _ => status.toUpperCase(),
};

String _formatMetric(num value, String unit) => switch (unit) {
  'microseconds' => '${(value / 1000).toStringAsFixed(3)} ms',
  'MiB/s' => '${value.toStringAsFixed(2)} MiB/s',
  'percent' => '${value.toStringAsFixed(1)}%',
  _ => '${value.toStringAsFixed(2)} $unit',
};

bool _nonEmptyString(Object? value) => value is String && value.isNotEmpty;
