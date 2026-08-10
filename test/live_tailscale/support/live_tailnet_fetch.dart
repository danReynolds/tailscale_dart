import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../e2e/support/native_asset_workaround.dart';

typedef LiveTailnetFetchOutcome = ({
  int? statusCode,
  String body,
  String? error,
});

/// Fetches [url] from a fresh ephemeral node on the publishing tailnet.
///
/// Each call owns a separate process, state root, app identity, and auth key.
/// Live auth keys are intentionally single-use and ephemeral nodes do not
/// provide a persisted reconnect identity.
Future<LiveTailnetFetchOutcome> runLiveTailnetFetch({
  required String hostname,
  required String authKey,
  required Uri url,
  String? controlUrl,
  Duration fetchBudget = const Duration(seconds: 150),
  Duration timeout = const Duration(minutes: 5),
}) async {
  await detachLoadedNativeAssetForPeerSubprocesses();
  final stateRoot = Directory.systemTemp.createTempSync('tailscale_live_peer_');
  final appSuffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      '--enable-experiment=native-assets',
      'test/live_tailscale/live_tls_fetch_main.dart',
    ],
    environment: {
      ...Platform.environment,
      'STATE_DIR': stateRoot.path,
      'APP_ID': 'dev.tailscale.dart.live.peer.$appSuffix',
      'HOSTNAME': hostname,
      'AUTH_KEY': authKey,
      'URL': url.toString(),
      'FETCH_BUDGET_SECONDS': '${fetchBudget.inSeconds}',
      if (controlUrl != null && controlUrl.isNotEmpty)
        'CONTROL_URL': controlUrl,
    },
  );

  final stderrBuffer = StringBuffer();
  unawaited(
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      stderrBuffer.write(chunk);
      stderr.write('[live tailnet peer stderr] $chunk');
    }),
  );

  final result = Completer<LiveTailnetFetchOutcome>();
  unawaited(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          stdout.writeln('[live tailnet peer] $line');
          if (result.isCompleted) return;
          if (line.startsWith('FETCH_ERROR ')) {
            final decoded =
                jsonDecode(line.substring('FETCH_ERROR '.length))
                    as Map<String, dynamic>;
            result.complete((
              statusCode: null,
              body: '',
              error: decoded['error'] as String? ?? 'unknown fetch error',
            ));
            return;
          }
          if (!line.startsWith('FETCH_RESULT ')) return;
          final decoded =
              jsonDecode(line.substring('FETCH_RESULT '.length))
                  as Map<String, dynamic>;
          result.complete((
            statusCode: decoded['status'] as int? ?? 0,
            body: decoded['body'] as String? ?? '',
            error: null,
          ));
        }),
  );

  final exitCode = process.exitCode;
  final exitedWithoutResult = exitCode.then<LiveTailnetFetchOutcome>((code) {
    if (result.isCompleted) return result.future;
    return (
      statusCode: null,
      body: '',
      error:
          'tailnet peer exited $code before reporting a fetch result: '
          '${stderrBuffer.toString().trim()}',
    );
  });

  try {
    return await Future.any<LiveTailnetFetchOutcome>([
      result.future,
      exitedWithoutResult,
    ]).timeout(
      timeout,
      onTimeout: () => (
        statusCode: null,
        body: '',
        error: 'timed out waiting for the in-tailnet peer to report',
      ),
    );
  } finally {
    try {
      process.kill(ProcessSignal.sigterm);
      await exitCode.timeout(const Duration(seconds: 15));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
    try {
      stateRoot.deleteSync(recursive: true);
    } catch (_) {}
  }
}
