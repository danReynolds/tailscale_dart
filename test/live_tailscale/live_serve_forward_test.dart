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

import '../e2e/support/native_asset_workaround.dart';
import '../e2e/support/state_waiters.dart';
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

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  String? stateDir;
  String? clientStateDir;
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
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final dir = clientStateDir;
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    api?.close();
  });

  test(
    'serve.forward proxies HTTPS tailnet traffic to a loopback HTTP server',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateDir = Directory.systemTemp
          .createTempSync('tailscale_live_serve_')
          .path;
      final authKey = await api!.createAuthKey();
      final clientAuthKey = await api!.createAuthKey();

      Tailscale.init(stateDir: stateDir!);
      tsnet = Tailscale.instance;
      await recordUntil(
        tsnet!,
        NodeState.running,
        () => tsnet!.up(
          hostname: hostname,
          authKey: authKey,
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
      } finally {
        await publication.close();
        await localServer.close(force: true);
        await localRequests.catchError((_) {});
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
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
  required String hostname,
  required String authKey,
  required String? controlUrl,
  required Uri url,
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
      'HOSTNAME': hostname,
      'AUTH_KEY': authKey,
      'URL': url.toString(),
      if (controlUrl != null && controlUrl.isNotEmpty)
        'CONTROL_URL': controlUrl,
    },
  );

  unawaited(
    process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => stderr.write('[live serve client stderr] $chunk')),
  );

  final result = Completer<({int statusCode, String body})>();
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
            result.completeError(
              StateError(
                'live Serve client failed: '
                '${decoded['error'] as String? ?? 'unknown error'}',
              ),
            );
            return;
          }
          if (!line.startsWith('FETCH_RESULT ')) return;
          final decoded =
              jsonDecode(line.substring('FETCH_RESULT '.length))
                  as Map<String, dynamic>;
          result.complete((
            statusCode: decoded['status'] as int? ?? 0,
            body: decoded['body'] as String? ?? '',
          ));
        }),
  );

  try {
    return await result.future.timeout(const Duration(seconds: 90));
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
