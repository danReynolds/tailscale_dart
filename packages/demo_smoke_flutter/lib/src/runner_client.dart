import 'dart:async';
import 'dart:convert';
import 'dart:io';

const smokeRunnerTokenHeader = 'x-dune-smoke-token';
const smokeRunnerHttpTimeout = Duration(seconds: 5);

final class SmokeRunnerConfig {
  const SmokeRunnerConfig({
    required this.controlUrl,
    required this.authKey,
    required this.targetIp,
    required this.hostname,
    required this.stateSuffix,
    this.mode = 'ephemeral',
    this.phase = 'single',
    this.expectedStableNodeId,
    this.expectedIpv4,
    this.profileSamples = 0,
    this.profileContext = 'primary',
    this.lanProfileHost,
    this.lanProfilePort,
  });

  final String controlUrl;
  final String? authKey;
  final String targetIp;
  final String hostname;
  final String stateSuffix;
  final String mode;
  final String phase;
  final String? expectedStableNodeId;
  final String? expectedIpv4;
  final int profileSamples;
  final String profileContext;
  final String? lanProfileHost;
  final int? lanProfilePort;
}

Future<SmokeRunnerConfig> fetchSmokeConfig({
  required Uri runnerUrl,
  required String session,
  required String token,
  Duration timeout = smokeRunnerHttpTimeout,
}) async {
  final uri = _runnerEndpoint(runnerUrl, '/config', session);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(smokeRunnerTokenHeader, token);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('runner /config returned HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final data = jsonDecode(body) as Map<String, dynamic>;
    final mode = data['mode'] as String? ?? 'ephemeral';
    if (mode != 'ephemeral' && mode != 'persistentCustody') {
      throw StateError('runner /config field mode is unsupported: $mode');
    }
    final phase = data['phase'] as String? ?? 'single';
    if (phase != 'single' && phase != 'enroll' && phase != 'reconnect') {
      throw StateError('runner /config field phase is unsupported: $phase');
    }
    if ((mode == 'ephemeral' && phase != 'single') ||
        (mode == 'persistentCustody' && phase == 'single')) {
      throw StateError(
        'runner /config mode $mode is incompatible with phase $phase',
      );
    }
    final authKey = data['authKey'];
    if (authKey != null && authKey is! String) {
      throw StateError('runner /config field authKey must be a string');
    }
    if ((mode == 'ephemeral' || phase == 'enroll') &&
        (authKey is! String || authKey.isEmpty)) {
      throw StateError('runner /config missing required field authKey');
    }
    return SmokeRunnerConfig(
      controlUrl: _requiredField(data, 'controlUrl'),
      authKey: authKey as String?,
      targetIp: _requiredField(data, 'targetIp'),
      hostname: data['hostname'] as String? ?? 'dune-smoke-$session',
      stateSuffix: data['stateSuffix'] as String? ?? session,
      mode: mode,
      phase: phase,
      expectedStableNodeId: data['expectedStableNodeId'] as String?,
      expectedIpv4: data['expectedIpv4'] as String?,
      profileSamples: _nonNegativeInt(data, 'profileSamples'),
      profileContext: data['profileContext'] as String? ?? 'primary',
      lanProfileHost: data['lanProfileHost'] as String?,
      lanProfilePort: _optionalPort(data, 'lanProfilePort'),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> postSmokeResult({
  required Uri runnerUrl,
  required String session,
  required String token,
  required Map<String, Object?> result,
  Duration timeout = smokeRunnerHttpTimeout,
}) async {
  final uri = _runnerEndpoint(runnerUrl, '/result', session);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers
      ..contentType = ContentType.json
      ..set(smokeRunnerTokenHeader, token);
    request.write(jsonEncode(result));
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Uri _runnerEndpoint(Uri runnerUrl, String path, String session) {
  return runnerUrl.replace(
    path: path,
    queryParameters: {...runnerUrl.queryParameters, 'session': session},
  );
}

String _requiredField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty) {
    throw StateError('runner /config missing required field $key');
  }
  return value;
}

int _nonNegativeInt(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value == null) return 0;
  if (value is! int || value < 0) {
    throw StateError(
      'runner /config field $key must be a non-negative integer',
    );
  }
  return value;
}

int? _optionalPort(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value == null) return null;
  if (value is! int || value < 1 || value > 65535) {
    throw StateError('runner /config field $key must be a valid port');
  }
  return value;
}
