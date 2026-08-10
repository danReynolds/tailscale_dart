/// Hosted-Tailscale receipt that one Funnel publication answers tailnet peers.
///
/// R5 models Funnel as the public-visibility mode of the same upstream
/// ServeConfig handler used by Serve. This isolates the tailnet vantage; the
/// existing live Funnel-forward test separately proves public ingress.
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
import 'dart:io';

import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import '../e2e/support/native_asset_workaround.dart';
import '../e2e/support/state_waiters.dart';
import '../integration/support/process_state_root.dart';
import 'support/live_tailnet_fetch.dart';
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
  Directory? stateRoot;
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
      final root = stateRoot;
      if (root != null) clearProcessIntegrationState(root);
    } catch (_) {}
    api?.close();
  });

  test(
    'a Funnel publication also answers inside the tailnet',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateRoot = processIntegrationStateRoot();
      clearProcessIntegrationState(stateRoot!);
      final authKey = await api!.createAuthKey();
      final peerAuthKey = await api!.createAuthKey();

      Tailscale.init(stateDir: stateRoot!.path, appId: processIntegrationAppId);
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
      final localServer = await _loopbackServer('hello from funnel');
      final publication = await tsnet!.funnel.forward(
        localPort: localServer.port,
      );

      try {
        final fromTailnet = await runLiveTailnetFetch(
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

        printOnFailure(
          'TAILNET -> '
          '${fromTailnet.error ?? '${fromTailnet.statusCode} ${fromTailnet.body}'}',
        );
        expect(
          fromTailnet.error,
          isNull,
          reason:
              'Funnel should add public visibility without removing tailnet '
              'reachability from the shared ServeConfig publication.',
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

Future<HttpServer> _loopbackServer(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    () async {
      await for (final request in server) {
        request.response.headers.contentType = ContentType.text;
        request.response.write(body);
        await request.response.close();
      }
    }().catchError((_) {}),
  );
  return server;
}

Future<List<String>> _waitForTlsDomains(Tailscale tsnet) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final domains = await tsnet.tls.domains();
    if (domains.isNotEmpty) return domains;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError(
    'No TLS cert domains appeared; HTTPS and MagicDNS must be enabled for '
    'this hosted Funnel receipt.',
  );
}
