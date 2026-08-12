/// Live Tailscale validation for Serve forwarding behavior Headscale cannot
/// prove.
///
/// Required environment:
///   TAILSCALE_API_KEY    - Tailscale API access token. Never committed.
///   TAILSCALE_TAILNET_ID - Tailnet API identifier; `-` is also supported.
///
/// Optional:
///   TAILSCALE_CONTROL_URL - Override control URL. Defaults to Tailscale SaaS.
///
/// Run:
///   TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
///     dart test test/live_tailscale/live_serve_forward_test.dart
@TestOn('mac-os || linux')
@Tags(['live-tailscale'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import '../e2e/support/native_asset_warmup.dart';
import '../e2e/support/state_waiters.dart';
import '../integration/support/process_state_root.dart';
import 'support/tailscale_api.dart';

void main() {
  final apiKey = Platform.environment['TAILSCALE_API_KEY'];
  final tailnetId = Platform.environment['TAILSCALE_TAILNET_ID'];
  final controlUrl = Platform.environment['TAILSCALE_CONTROL_URL'];

  if (apiKey == null ||
      apiKey.isEmpty ||
      tailnetId == null ||
      tailnetId.isEmpty) {
    test(
      'live Tailscale Serve forwarding',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-serve-$suffix';
  final clientHostname = 'dune-live-serve-client-$suffix';
  final cleanupClientHostname = 'dune-live-serve-cleanup-$suffix';

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  String? stateDir;
  String? clientStateDir;
  String? cleanupClientStateDir;
  final deviceIdsToDelete = <String>{};

  Uri? controlUri() {
    if (controlUrl == null || controlUrl.isEmpty) return null;
    return Uri.parse(controlUrl);
  }

  tearDownAll(() async {
    try {
      await tsnet?.down();
    } catch (_) {}
    for (final id in deviceIdsToDelete) {
      try {
        await api?.deleteDevice(id);
      } catch (_) {}
    }
    try {
      final dir = stateDir;
      if (dir != null) clearProcessIntegrationState(Directory(dir));
    } catch (_) {}
    try {
      final dir = clientStateDir;
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final dir = cleanupClientStateDir;
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    api?.close();
  });

  test(
    'serve.forward proxies HTTPS tailnet traffic to a loopback HTTP server',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      final processStateRoot = processIntegrationStateRoot();
      clearProcessIntegrationState(processStateRoot);
      stateDir = processStateRoot.path;
      final authKey = await api!.createAuthKey();
      final replacementAuthKey = await api!.createAuthKey();
      final clientAuthKey = await api!.createAuthKey();
      final cleanupPathClientAuthKey = await api!.createAuthKey();
      final cleanupClientAuthKey = await api!.createAuthKey();

      Tailscale.init(stateDir: stateDir!, appId: processIntegrationAppId);
      tsnet = Tailscale.instance;
      await recordUntil(
        tsnet!,
        NodeState.running,
        () => tsnet!.up(
          hostname: hostname,
          authKey: authKey,
          ephemeral: true,
          controlUrl: controlUri(),
          timeout: const Duration(seconds: 120),
        ),
      );

      final device = await api!.waitForDevice(
        hostname: hostname,
        ipv4: (await tsnet!.status()).ipv4,
      );
      deviceIdsToDelete.add(device.id);

      final domains = await _waitForTlsDomains(tsnet!);
      final localServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final localRequests = _serveLoopback(localServer);
      unawaited(localRequests.catchError((_) {}));

      final publication = await tsnet!.serve.forward(
        tailnetPort: 443,
        localPort: localServer.port,
      );
      try {
        clientStateDir = Directory.systemTemp
            .createTempSync('tailscale_live_serve_client_')
            .path;
        final response = await _runClientFetch(
          stateDir: clientStateDir!,
          appId: 'dev.tailscale.dart.live.serve.client',
          hostname: clientHostname,
          authKey: clientAuthKey,
          controlUrl: controlUrl,
          url: Uri.https(domains.first, '/live-serve'),
        );

        try {
          final clientDevice = await api!.waitForDevice(
            hostname: clientHostname,
          );
          deviceIdsToDelete.add(clientDevice.id);
        } catch (_) {}

        expect(publication.url.toString(), 'https://${domains.first}/');
        expect(response.statusCode, 200);
        expect(response.body, 'hello from serve');

        await publication.close();

        final cleanupPublication = await tsnet!.serve.forward(
          tailnetPort: 443,
          localPort: localServer.port,
          path: '/cleanup',
        );
        final cleanupUrl = Uri.https(domains.first, '/cleanup');
        final cleanupResponse = await _runClientFetch(
          stateDir: clientStateDir!,
          appId: 'dev.tailscale.dart.live.serve.client',
          hostname: clientHostname,
          // Ephemeral clients do not retain identity, and live auth keys are
          // intentionally single-use. Each subprocess therefore needs a new
          // key even when the scratch directory and hostname are reused.
          authKey: cleanupPathClientAuthKey,
          controlUrl: controlUrl,
          url: cleanupUrl,
        );
        expect(
          cleanupPublication.url.toString(),
          'https://${domains.first}/cleanup',
        );
        expect(cleanupResponse.statusCode, 200);
        expect(cleanupResponse.body, 'hello from serve');

        // Do not close cleanupPublication. This is an orderly down/up smoke:
        // down() should remove package-owned Serve config before a fresh
        // ephemeral identity starts in the same Dart process. It does not
        // exercise process death or persisted-state crash recovery.
        await tsnet!.down();
        await recordUntil(
          tsnet!,
          NodeState.running,
          () => tsnet!.up(
            hostname: hostname,
            authKey: replacementAuthKey,
            ephemeral: true,
            controlUrl: controlUri(),
            timeout: const Duration(seconds: 120),
          ),
          timeout: const Duration(seconds: 120),
        );

        cleanupClientStateDir = Directory.systemTemp
            .createTempSync('tailscale_live_serve_cleanup_client_')
            .path;
        final cleanupAfterReplacement = await _runClientFetchOutcome(
          stateDir: cleanupClientStateDir!,
          appId: 'dev.tailscale.dart.live.serve.cleanupClient',
          hostname: cleanupClientHostname,
          authKey: cleanupClientAuthKey,
          controlUrl: controlUrl,
          url: cleanupUrl,
          fetchBudget: const Duration(seconds: 20),
        );
        try {
          final cleanupClientDevice = await api!.waitForDevice(
            hostname: cleanupClientHostname,
          );
          deviceIdsToDelete.add(cleanupClientDevice.id);
        } catch (_) {}
        if (cleanupAfterReplacement.statusCode == 200 &&
            cleanupAfterReplacement.body == 'hello from serve') {
          fail(
            'serve.forward publication survived an orderly down/up lifecycle '
            'replacement without an explicit close().',
          );
        }
      } finally {
        await localServer.close(force: true);
        await localRequests.catchError((_) {});
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

Future<void> _serveLoopback(HttpServer server) async {
  await for (final request in server) {
    request.response.headers.contentType = ContentType.text;
    request.response.write('hello from serve');
    await request.response.close();
  }
}

Future<({int statusCode, String body})> _runClientFetch({
  required String stateDir,
  required String appId,
  required String hostname,
  required String authKey,
  required String? controlUrl,
  required Uri url,
}) async {
  final outcome = await _runClientFetchOutcome(
    stateDir: stateDir,
    appId: appId,
    hostname: hostname,
    authKey: authKey,
    controlUrl: controlUrl,
    url: url,
  );
  final error = outcome.error;
  if (error != null) {
    throw StateError('live Serve client failed: $error');
  }
  return (statusCode: outcome.statusCode ?? 0, body: outcome.body);
}

Future<({int? statusCode, String body, String? error})> _runClientFetchOutcome({
  required String stateDir,
  required String appId,
  required String hostname,
  required String authKey,
  required String? controlUrl,
  required Uri url,
  Duration fetchBudget = const Duration(seconds: 150),
}) async {
  await detachLoadedNativeAssetForPeerSubprocesses();
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      '--enable-experiment=native-assets',
      'test/live_tailscale/live_tls_fetch_main.dart',
    ],
    environment: {
      ...Platform.environment,
      'STATE_DIR': stateDir,
      'APP_ID': appId,
      'HOSTNAME': hostname,
      'AUTH_KEY': authKey,
      'URL': url.toString(),
      'FETCH_BUDGET_SECONDS': '${fetchBudget.inSeconds}',
      if (controlUrl != null && controlUrl.isNotEmpty)
        'CONTROL_URL': controlUrl,
    },
  );

  unawaited(
    process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => stderr.write('[live serve client stderr] $chunk')),
  );

  final result = Completer<({int? statusCode, String body, String? error})>();
  unawaited(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          stdout.writeln('[live serve client] $line');
          if (result.isCompleted) return;
          if (line.startsWith('FETCH_ERROR ')) {
            final decoded =
                jsonDecode(line.substring('FETCH_ERROR '.length))
                    as Map<String, dynamic>;
            result.complete((
              statusCode: null,
              body: '',
              error: decoded['error'] as String? ?? 'unknown error',
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

  try {
    return await result.future.timeout(const Duration(minutes: 5));
  } finally {
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(const Duration(seconds: 15));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }
}

Future<List<String>> _waitForTlsDomains(Tailscale tsnet) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  List<String> last = const [];
  while (DateTime.now().isBefore(deadline)) {
    last = await tsnet.tls.domains();
    if (last.isNotEmpty) return last;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail(
    'tls.domains() stayed empty. This live test requires MagicDNS and HTTPS '
    'enabled on the Tailscale tailnet. Last domains: $last',
  );
}
