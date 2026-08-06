/// Does a Funnel publication answer requests from inside the publisher's own
/// tailnet?
///
/// This is the clean case for issue #87: a single `funnel.forward` and nothing
/// else on the port. The sibling swap test always has a `serve.forward` mount
/// on the same port, which confounds the reading — so this file exists to
/// isolate the question that motivated dropping `tsnet.FunnelOnly()`.
///
/// Upstream serves both by default ("connections can come from either inside or
/// outside your network", tsnet.ListenFunnel), and `tailscale funnel` behaves
/// that way. We passed FunnelOnly from the first commit of the feature, so a
/// publication answered the internet but reset the developer's own laptop —
/// with no error anywhere. This asserts the aligned behavior.
///
/// The client is a second real node using `tsnet.http.client`, so the request
/// travels the tailnet rather than egressing to the public internet. Public
/// reachability is covered by live_funnel_forward_test.dart and is deliberately
/// not re-tested here.
///
/// Required environment:
///   TAILSCALE_API_KEY    - Tailscale API access token. Never committed.
///   TAILSCALE_TAILNET_ID - Tailnet API identifier; `-` is also supported.
///
/// Run:
///   TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
///     dart test test/live_tailscale/live_funnel_tailnet_reach_test.dart
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
      'live Tailscale Funnel tailnet reachability',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-freach-$suffix';
  final peerHostname = 'dune-live-freach-peer-$suffix';

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  String? stateDir;
  String? peerStateDir;
  final deviceIdsToDelete = <String>{};

  tearDownAll(() async {
    try {
      await tsnet?.down();
    } catch (_) {}
    for (final id in deviceIdsToDelete) {
      try {
        await api?.deleteDevice(id);
      } catch (_) {}
    }
    for (final dir in [stateDir, peerStateDir]) {
      try {
        if (dir != null) Directory(dir).deleteSync(recursive: true);
      } catch (_) {}
    }
    api?.close();
  });

  test(
    'a Funnel publication also answers requests from inside the tailnet',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateDir = Directory.systemTemp
          .createTempSync('tailscale_live_freach_')
          .path;
      peerStateDir = Directory.systemTemp
          .createTempSync('tailscale_live_freach_peer_')
          .path;
      // Auth keys are minted non-reusable, so the client needs its own.
      final authKey = await api!.createAuthKey();
      final peerAuthKey = await api!.createAuthKey();

      Tailscale.init(stateDir: stateDir!);
      tsnet = Tailscale.instance;
      await recordUntil(
        tsnet!,
        NodeState.running,
        () => tsnet!.up(
          hostname: hostname,
          authKey: authKey,
          ephemeral: true,
          controlUrl: controlUrl == null || controlUrl.isEmpty
              ? null
              : Uri.parse(controlUrl),
          timeout: const Duration(seconds: 120),
        ),
      );

      final device = await api!.waitForDevice(
        hostname: hostname,
        ipv4: (await tsnet!.status()).ipv4,
      );
      deviceIdsToDelete.add(device.id);

      final domains = await _waitForTlsDomains(tsnet!);
      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(() async {
        await for (final request in localServer) {
          request.response.headers.contentType = ContentType.text;
          request.response.write('hello from funnel');
          await request.response.close();
        }
      }().catchError((_) {}));

      final publication = await tsnet!.funnel.forward(
        publicPort: 443,
        localAddress: InternetAddress.loopbackIPv4.address,
        localPort: localServer.port,
      );

      try {
        final fromTailnet = await _fetchFromTailnet(
          stateDir: peerStateDir!,
          hostname: peerHostname,
          authKey: peerAuthKey,
          controlUrl: controlUrl,
          url: Uri.https(domains.first, '/'),
        );
        try {
          deviceIdsToDelete.add(
            (await api!.waitForDevice(hostname: peerHostname)).id,
          );
        } catch (_) {}

        stdout.writeln(
          'TAILNET -> ${fromTailnet.error ?? '${fromTailnet.statusCode} ${fromTailnet.body}'}',
        );

        expect(
          fromTailnet.error,
          isNull,
          reason:
              'A Funnel publication should be reachable from inside the '
              'publishing tailnet, matching tsnet.ListenFunnel default and '
              '`tailscale funnel`. A failure here means the listener is not '
              'serving the tailnet side (issue #87).',
        );
        expect(fromTailnet.statusCode, 200);
        expect(fromTailnet.body, 'hello from funnel');
      } finally {
        await publication.close();
        await localServer.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<({int? statusCode, String body, String? error})> _fetchFromTailnet({
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
      if (controlUrl != null && controlUrl.isNotEmpty) 'CONTROL_URL': controlUrl,
    },
  );

  unawaited(
    process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => stderr.write('[tailnet client stderr] $chunk')),
  );

  final result = Completer<({int? statusCode, String body, String? error})>();
  unawaited(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          stdout.writeln('[tailnet client] $line');
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
    return await result.future.timeout(const Duration(seconds: 150));
  } on TimeoutException {
    return (
      statusCode: null,
      body: '',
      error: 'timed out waiting for the in-tailnet client to report',
    );
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
  while (DateTime.now().isBefore(deadline)) {
    final domains = await tsnet.tls.domains();
    if (domains.isNotEmpty) return domains;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError(
    'No TLS cert domains appeared; HTTPS certificates must be enabled for the '
    'tailnet before Funnel can work.',
  );
}
