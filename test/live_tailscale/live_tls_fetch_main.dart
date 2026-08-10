/// Helper subprocess for `live_tls_listener_test.dart`.
///
/// Joins the live tailnet as a second node, fetches the HTTPS URL through
/// `tsnet.http.client`, prints one machine-readable `FETCH_RESULT ...` line,
/// then exits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  final stateDir = _requiredEnv('STATE_DIR');
  final appId = _requiredEnv('APP_ID');
  final authKey = _requiredEnv('AUTH_KEY');
  final hostname = _requiredEnv('HOSTNAME');
  final url = Uri.parse(_requiredEnv('URL'));
  final controlUrl = Platform.environment['CONTROL_URL'];
  final fetchBudgetSeconds = int.tryParse(
    Platform.environment['FETCH_BUDGET_SECONDS'] ?? '',
  );
  final fetchBudget = Duration(
    seconds: fetchBudgetSeconds != null && fetchBudgetSeconds > 0
        ? fetchBudgetSeconds
        : 150,
  );

  Tailscale.init(stateDir: stateDir, appId: appId);
  final tsnet = Tailscale.instance;

  try {
    final running = Completer<void>();
    final stateSubscription = tsnet.onStateChange.listen((state) {
      if (state == NodeState.running && !running.isCompleted) {
        running.complete();
      }
    });
    try {
      final initial = await tsnet.up(
        hostname: hostname,
        authKey: authKey,
        ephemeral: true,
        controlUrl: controlUrl == null || controlUrl.isEmpty
            ? null
            : Uri.parse(controlUrl),
        timeout: const Duration(seconds: 120),
      );
      if (initial.isRunning && !running.isCompleted) {
        running.complete();
      }
      await running.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw TimeoutException(
          'live tailnet peer never reached package-level Running after auth',
        ),
      );
    } finally {
      await stateSubscription.cancel();
    }

    final status = await tsnet.status();
    stdout.writeln('CLIENT_READY ${status.ipv4 ?? ''}');

    final deadline = DateTime.now().add(fetchBudget);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await tsnet.http.client
            .get(url)
            .timeout(const Duration(seconds: 45));
        stdout.writeln(
          'FETCH_RESULT ${jsonEncode({'status': response.statusCode, 'body': response.body})}',
        );
        return;
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    stdout.writeln(
      'FETCH_ERROR ${jsonEncode({'error': lastError?.toString() ?? 'fetch budget expired'})}',
    );
    exitCode = 3;
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
