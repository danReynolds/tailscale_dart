import 'dart:convert';

import 'package:tailscale_profile_harness/tailscale_profile_harness.dart';
import 'package:test/test.dart';

import '../../tool/smoke/result_report.dart';

void main() {
  test('capability matrix keeps diagnostic ping non-blocking', () {
    final run = _run(profile: false);
    final capabilities = smokeCapabilities(run);

    expect(_capability(capabilities, 'overall')['status'], 'pass');
    expect(_capability(capabilities, 'join')['status'], 'pass');
    expect(_capability(capabilities, 'ping')['status'], 'warn');
    expect(_capability(capabilities, 'ping')['required'], isFalse);
    expect(_capability(capabilities, 'udpEcho')['status'], 'pass');
    expect(_capability(capabilities, 'restart')['status'], 'pass');
    expect(_capability(capabilities, 'profile')['status'], 'notRun');

    final matrix = renderSmokeCapabilityMatrix([run]);
    expect(matrix, contains('ios'));
    expect(matrix, contains('WARN'));
    expect(matrix, contains('Ping is diagnostic'));
  });

  test('artifact retains raw samples and omits tailnet addresses', () {
    final artifact = buildSmokeRunArtifact(
      runs: [_run(profile: true)],
      source: const <String, Object?>{
        'package': 'tailscale',
        'version': '0.8.1',
        'commit': 'abc123',
        'dirty': false,
      },
      environment: const <String, Object?>{
        'flutter': '3.44.4',
        'dart': '3.12.2',
        'flutterRunMode': 'profile',
        'flutterLaunchMode': 'detached',
      },
      profileSamples: 2,
      profileContext: 'primary',
      generatedAt: DateTime.utc(2026, 8, 12),
    );
    final target = (artifact['targets'] as List).single as Map<String, Object?>;
    final profile = target['profile'] as Map<String, Object?>;
    final capabilities = (target['capabilities'] as List)
        .cast<Map<String, Object?>>();
    final throughput = (profile['throughput'] as List)
        .cast<Map<String, Object?>>();
    final upload = throughput.singleWhere(
      (value) => value['direction'] == 'upload',
    );
    final lanThroughput = (profile['lanThroughput'] as List)
        .cast<Map<String, Object?>>();
    final nativeThroughput = (profile['nativeTsnetThroughput'] as List)
        .cast<Map<String, Object?>>();
    final bridgeRatios = (profile['dartApiToNativeTsnet'] as List)
        .cast<Map<String, Object?>>();

    expect(profile['valid'], isTrue);
    expect(_capability(capabilities, 'profile')['status'], 'pass');
    expect(profile['networkPaths'], {'direct': 2});
    expect(profile['comparisonEligible'], isTrue);
    expect(upload['sampleCount'], 3);
    expect(upload['samples'], [10.0, 20.0, 15.0]);
    expect(upload['median'], 15.0);
    expect(profile['lanControlComplete'], isTrue);
    expect(profile['nativeTsnetControlComplete'], isTrue);
    expect(lanThroughput, hasLength(2));
    expect(nativeThroughput, hasLength(2));
    expect(
      bridgeRatios.singleWhere((value) => value['direction'] == 'upload'),
      containsPair('medianPercent', 75.0),
    );
    expect(profile['writeCompletion'], isNotEmpty);
    expect(jsonEncode(artifact), isNot(contains('100.64.0.2')));

    final markdown = renderSmokeRunMarkdown(artifact);
    expect(markdown, contains('Correctness matrix'));
    expect(markdown, contains('Dart public API over Tailscale'));
    expect(markdown, contains('Device-side direct tsnet control'));
    expect(markdown, contains('same remote Dart peer'));
    expect(markdown, contains('Dart API / direct tsnet client'));
    expect(markdown, contains('Ordinary LAN control'));
    expect(markdown, contains('sender write completion'));
    expect(markdown, contains('direct=2'));
    expect(markdown, contains('Flutter launch mode: `detached`'));
  });

  test('an invalid profile does not turn correctness into a failure', () {
    final run = _run(profile: true, profileStatus: 'invalid');
    final capabilities = smokeCapabilities(run);

    expect(_capability(capabilities, 'overall')['status'], 'pass');
    expect(_capability(capabilities, 'profile')['status'], 'warn');
    expect(_capability(capabilities, 'profile')['required'], isFalse);
  });

  test('debug profile stays valid but is not history-comparable', () {
    final artifact = buildSmokeRunArtifact(
      runs: [_run(profile: true)],
      source: const <String, Object?>{},
      environment: const <String, Object?>{'flutterRunMode': 'debug'},
      profileSamples: 2,
      profileContext: 'simulator-diagnostic',
    );
    final target = (artifact['targets'] as List).single as Map<String, Object?>;
    final profile = target['profile'] as Map<String, Object?>;

    expect(profile['valid'], isTrue);
    expect(profile['comparisonEligible'], isFalse);
    expect(profile['comparisonIneligibleReason'], contains('diagnostic only'));
    expect(
      renderSmokeRunMarkdown(artifact),
      contains('Flutter run mode: `debug`'),
    );
  });

  test('missing native tsnet control invalidates profile collection', () {
    final run = _run(profile: true);
    final result = run['result']! as Map<String, Object?>;
    final rawProfile = result['profile']! as Map<String, Object?>;
    rawProfile['nativeTsnetSpeedTests'] = <Object?>[];
    final artifact = buildSmokeRunArtifact(
      runs: [run],
      source: const <String, Object?>{},
      environment: const <String, Object?>{'flutterRunMode': 'profile'},
      profileSamples: 2,
      profileContext: 'primary',
    );
    final target = (artifact['targets'] as List).single as Map<String, Object?>;
    final profile = target['profile'] as Map<String, Object?>;

    expect(profile['valid'], isFalse);
    expect(profile['comparisonEligible'], isFalse);
    expect(profile['nativeTsnetControlComplete'], isFalse);
  });

  test('missing target produces an explicit skipped matrix row', () {
    final run = <String, Object?>{
      'target': 'android',
      'ok': true,
      'skipped': true,
    };

    expect(smokeCapabilities(run).map((value) => value['status']).toSet(), {
      'skip',
    });
    expect(renderSmokeCapabilityMatrix([run]), contains('SKIP'));
  });
}

Map<String, Object?> _run({
  required bool profile,
  String profileStatus = 'complete',
}) {
  final firstReport = _report(pingOk: false, pingUs: 9000, networkUs: 3000);
  return <String, Object?>{
    'target': 'ios',
    'ok': true,
    'skipped': false,
    'device': const <String, Object?>{
      'targetPlatform': 'ios-arm64',
      'platformType': 'ios',
      'emulator': false,
      'sdk': 'iOS 18.7.3',
    },
    'result': <String, Object?>{
      'ok': true,
      'durationMs': 37000,
      'localIp': '100.64.0.1',
      'targetIp': '100.64.0.2',
      'nodesSeen': 1,
      'report': firstReport,
      'restart': <String, Object?>{'ok': true, 'report': firstReport},
      if (profile)
        'profile': <String, Object?>{
          'status': profileStatus,
          'valid': profileStatus == 'complete',
          'context': 'primary',
          'sampleCount': 2,
          'reports': [
            _report(pingOk: true, pingUs: 5000, networkUs: 2000),
            _report(pingOk: true, pingUs: 7000, networkUs: 3000),
          ],
          'speedTests': [
            _speedTest('upload', 10),
            _speedTest('download', 30),
            _speedTest('download', 40),
            _speedTest('upload', 20),
            _speedTest('upload', 15),
            _speedTest('download', 35),
          ],
          'nativeTsnetSpeedTests': [
            _speedTest('upload', 20),
            _speedTest('download', 50),
            _speedTest('download', 50),
            _speedTest('upload', 20),
            _speedTest('upload', 20),
            _speedTest('download', 50),
          ],
          'lanSpeedTests': [
            _lanSpeedTest('upload', 100),
            _lanSpeedTest('download', 110),
          ],
        },
    },
  };
}

Map<String, Object?> _report({
  required bool pingOk,
  required int pingUs,
  required int networkUs,
}) {
  Map<String, Object?> probe(String kind, int durationUs) => <String, Object?>{
    'kind': kind,
    'ok': true,
    'durationUs': durationUs,
  };

  return <String, Object?>{
    'ok': pingOk,
    'requiredOk': true,
    'nodeIp': '100.64.0.2',
    'results': <Map<String, Object?>>[
      <String, Object?>{
        'kind': 'ping',
        'ok': pingOk,
        'durationUs': pingUs,
        if (pingOk) 'networkLatencyUs': networkUs,
        if (pingOk) 'networkPath': 'direct',
      },
      probe('whois', 1000),
      probe('httpGet', 2000),
      probe('httpPost', 3000),
      probe('tcpEcho', 4000),
      probe('udpEcho', 5000),
    ],
  };
}

Map<String, Object?> _speedTest(String direction, double rate) =>
    <String, Object?>{
      'comparisonEligible': true,
      'pathBefore': const <String, Object?>{'networkPath': 'direct'},
      'pathAfter': const <String, Object?>{'networkPath': 'direct'},
      'result': <String, Object?>{
        'valid': true,
        'direction': direction,
        'config': canonicalSpeedTestConfig.toJson(),
        'mibPerSecond': rate,
        'writeCompletion': const <String, Object?>{
          'sampleCount': 10,
          'minUs': 10,
          'p50Us': 20,
          'p95Us': 30,
          'p99Us': 40,
          'maxUs': 50,
        },
        'intervals': const <Object?>[],
      },
    };

Map<String, Object?> _lanSpeedTest(String direction, double rate) =>
    <String, Object?>{
      'valid': true,
      'direction': direction,
      'config': ordinaryLanControlConfig.toJson(),
      'mibPerSecond': rate,
      'writeCompletion': const <String, Object?>{
        'sampleCount': 10,
        'minUs': 5,
        'p50Us': 10,
        'p95Us': 15,
        'p99Us': 20,
        'maxUs': 25,
      },
    };

Map<String, Object?> _capability(
  List<Map<String, Object?>> capabilities,
  String id,
) => capabilities.singleWhere((value) => value['id'] == id);
