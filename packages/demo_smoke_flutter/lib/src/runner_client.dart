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
  });

  final String controlUrl;
  final String authKey;
  final String targetIp;
  final String hostname;
  final String stateSuffix;
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
    return SmokeRunnerConfig(
      controlUrl: _requiredField(data, 'controlUrl'),
      authKey: _requiredField(data, 'authKey'),
      targetIp: _requiredField(data, 'targetIp'),
      hostname: data['hostname'] as String? ?? 'dune-smoke-$session',
      stateSuffix: data['stateSuffix'] as String? ?? session,
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
