/// Helper subprocess for `live_tls_listener_test.dart`.
///
/// Joins the live tailnet as a second node, fetches the HTTPS URL through
/// `tsnet.http.client`, prints one machine-readable `FETCH_RESULT ...` line,
/// then exits.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  final stateDir = _requiredEnv('STATE_DIR');
  final authKey = _requiredEnv('AUTH_KEY');
  final hostname = _requiredEnv('HOSTNAME');
  final url = Uri.parse(_requiredEnv('URL'));
  final controlUrl = Platform.environment['CONTROL_URL'];

  Tailscale.init(stateDir: stateDir);
  final tsnet = Tailscale.instance;

  try {
    await tsnet.up(
      hostname: hostname,
      authKey: authKey,
      controlUrl: controlUrl == null || controlUrl.isEmpty
          ? null
          : Uri.parse(controlUrl),
      timeout: const Duration(seconds: 120),
    );

    final status = await tsnet.status();
    stdout.writeln('CLIENT_READY ${status.ipv4 ?? ''}');

    try {
      final response = await tsnet.http.client
          .get(url)
          .timeout(const Duration(seconds: 45));
      stdout.writeln(
        'FETCH_RESULT ${jsonEncode({'status': response.statusCode, 'body': response.body})}',
      );
    } catch (error) {
      stdout.writeln('FETCH_ERROR ${jsonEncode({'error': error.toString()})}');
      exitCode = 3;
    }
  } finally {
    try {
      await tsnet.down();
    } catch (_) {}
  }
}

String _requiredEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    stderr.writeln('live_tls_fetch: missing required env var $name');
    exit(2);
  }
  return value;
}
