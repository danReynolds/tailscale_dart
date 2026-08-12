/// Hosted-Tailscale receipt for Serve/Funnel replacement on one coordinate.
///
/// Regression coverage for <https://github.com/danReynolds/tailscale_dart/issues/87>:
/// switching a working private Serve publication to Funnel must make the same
/// port publicly reachable instead of leaving it blocked.
///
/// Serve and Funnel now mutate one upstream ServeConfig authority. A later
/// call for the same port and path replaces the handler and visibility mode;
/// its exact handle cannot be cleared by an older handle.
///
/// Required environment:
///   TAILSCALE_API_KEY    - Tailscale API access token. Never committed.
///   TAILSCALE_TAILNET_ID - Tailnet API identifier; `-` is also supported.
///
/// Run:
///   TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
///     dart test test/live_tailscale/live_funnel_serve_swap_test.dart
@TestOn('mac-os || linux')
@Tags(['live-tailscale'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import '../e2e/support/state_waiters.dart';
import '../support/persistent_state_inventory.dart';
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
      'live Tailscale Serve/Funnel swap',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-swap-$suffix';

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  Directory? stateRoot;
  final deviceIdsToDelete = <String>{};

  Uri? controlUri() {
    if (controlUrl == null || controlUrl.isEmpty) return null;
    return Uri.parse(controlUrl);
  }

  Future<void> rememberPeer(String peerHostname) async {
    try {
      deviceIdsToDelete.add(
        (await api!.waitForDevice(hostname: peerHostname)).id,
      );
    } catch (_) {}
  }

  tearDownAll(() async {
    try {
      await tsnet?.forgetLocalIdentity();
    } catch (_) {}
    for (final id in deviceIdsToDelete) {
      try {
        await api?.deleteDevice(id);
      } catch (_) {}
    }
    try {
      final root = stateRoot;
      if (root != null && root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
    api?.close();
  });

  test(
    'issue #87: Serve -> Funnel -> Serve uses one mapping and exact handles',
    () async {
      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateRoot = Directory.systemTemp.createTempSync(
        'tailscale_live_swap_persistent_',
      );
      final publisherAuthKey = await api!.createAuthKey();

      Tailscale.init(
        stateDir: stateRoot!.path,
        appId: 'dev.tailscale.dart.live.swap.$suffix',
      );
      tsnet = Tailscale.instance;
      await recordUntil(
        tsnet!,
        NodeState.running,
        () => tsnet!.up(
          hostname: hostname,
          authKey: publisherAuthKey,
          controlUrl: controlUri(),
          timeout: const Duration(seconds: 120),
        ),
      );

      final device = await api!.waitForDevice(
        hostname: hostname,
        ipv4: (await tsnet!.status()).ipv4,
      );
      deviceIdsToDelete.add(device.id);
      final fqdn = (await _waitForTlsDomains(tsnet!)).first;
      final url = Uri.https(fqdn, '/');
      final serveBackend = await _loopbackServer('hello from serve');
      final funnelBackend = await _loopbackServer('hello from funnel');

      TailscalePublishedService? serveHandle;
      TailscalePublishedService? funnelHandle;
      TailscalePublishedService? replacementServeHandle;
      try {
        serveHandle = await tsnet!.serve.forward(
          tailnetPort: 443,
          localPort: serveBackend.port,
        );
        final servePeer = 'dune-live-swap-serve-$suffix';
        final serveBaseline = await runLiveTailnetFetch(
          hostname: servePeer,
          authKey: await api!.createAuthKey(),
          controlUrl: controlUrl,
          url: url,
        );
        await rememberPeer(servePeer);
        _expectBody(serveBaseline, 'hello from serve', 'Serve baseline');

        funnelHandle = await tsnet!.funnel.forward(
          localPort: funnelBackend.port,
        );
        await serveHandle.close();

        final addresses = await _waitForPublicDns(fqdn);
        final publicFetch = await _waitForPublicFetch(url, addresses);
        final funnelPeer = 'dune-live-swap-funnel-$suffix';
        final tailnetFunnel = await runLiveTailnetFetch(
          hostname: funnelPeer,
          authKey: await api!.createAuthKey(),
          controlUrl: controlUrl,
          url: url,
        );
        await rememberPeer(funnelPeer);

        expect(publicFetch.statusCode, 200);
        expect(publicFetch.body, 'hello from funnel');
        _expectBody(
          tailnetFunnel,
          'hello from funnel',
          'Funnel after stale Serve-handle close',
        );

        replacementServeHandle = await tsnet!.serve.forward(
          tailnetPort: 443,
          localPort: serveBackend.port,
        );
        await funnelHandle.close();

        final replacementPeer = 'dune-live-swap-replacement-$suffix';
        final replacementServe = await runLiveTailnetFetch(
          hostname: replacementPeer,
          authKey: await api!.createAuthKey(),
          controlUrl: controlUrl,
          url: url,
        );
        await rememberPeer(replacementPeer);
        _expectBody(
          replacementServe,
          'hello from serve',
          'Serve after stale Funnel-handle close',
        );

        await replacementServeHandle.close();
        final clearedPeer = 'dune-live-swap-cleared-$suffix';
        final afterClose = await runLiveTailnetFetch(
          hostname: clearedPeer,
          authKey: await api!.createAuthKey(),
          controlUrl: controlUrl,
          url: url,
          fetchBudget: const Duration(seconds: 20),
        );
        await rememberPeer(clearedPeer);
        expect(
          afterClose.statusCode == 200 &&
              (afterClose.body == 'hello from serve' ||
                  afterClose.body == 'hello from funnel'),
          isFalse,
          reason: 'Closing the current exact handle must remove the mapping.',
        );
      } finally {
        await replacementServeHandle?.close();
        await funnelHandle?.close();
        await serveHandle?.close();
        await serveBackend.close(force: true);
        await funnelBackend.close(force: true);
      }

      final inventory = auditPersistentRuntimeInventory(stateRoot!.path);
      stdout.writeln(
        'R6_SERVE_FUNNEL_STATE_INVENTORY ${jsonEncode(inventory)}',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

void _expectBody(LiveTailnetFetchOutcome outcome, String body, String phase) {
  expect(outcome.error, isNull, reason: '$phase failed: ${outcome.error}');
  expect(outcome.statusCode, 200, reason: phase);
  expect(outcome.body, body, reason: phase);
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
    'this hosted Serve/Funnel receipt.',
  );
}

Future<({int statusCode, String body})> _waitForPublicFetch(
  Uri url,
  List<InternetAddress> addresses,
) async {
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  var lastErrors = <String>[];
  while (DateTime.now().isBefore(deadline)) {
    final errors = <String>[];
    for (final address in addresses) {
      try {
        final response = await _fetchViaAddress(url, address);
        if (response.statusCode == 200) return response;
        errors.add(
          '${address.address}: HTTP ${response.statusCode}: ${response.body}',
        );
      } catch (error) {
        errors.add('${address.address}: $error');
      }
    }
    lastErrors = errors;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError(
    'Funnel URL $url did not become publicly reachable: '
    '${lastErrors.join('; ')}',
  );
}

Future<List<InternetAddress>> _waitForPublicDns(String host) async {
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final v4 = await _publicDnsRecords(host, 'A');
      final v6 = await _publicDnsRecords(host, 'AAAA');
      final addresses = v4.isNotEmpty ? v4 : v6;
      if (addresses.isNotEmpty) return addresses;
      lastError = 'no public A/AAAA record yet';
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  throw StateError(
    'Funnel hostname $host did not appear in public DNS: $lastError',
  );
}

Future<List<InternetAddress>> _publicDnsRecords(
  String host,
  String type,
) async {
  final response = await http
      .get(
        Uri.https('dns.google', '/resolve', {'name': host, 'type': type}),
        headers: const {'Accept': 'application/dns-json'},
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    throw StateError(
      'DNS-over-HTTPS query failed with HTTP ${response.statusCode}: '
      '${response.body}',
    );
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, Object?>) {
    throw StateError('DNS-over-HTTPS returned non-object JSON.');
  }
  if (decoded['Status'] != 0) return const [];
  return [
    for (final answer in decoded['Answer'] as List? ?? const [])
      if (answer is Map<String, Object?> && answer['data'] is String)
        InternetAddress(answer['data']! as String),
  ];
}

Future<({int statusCode, String body})> _fetchViaAddress(
  Uri url,
  InternetAddress address,
) async {
  const statusMarker = '__DUNE_STATUS__:';
  final result = await Process.run('curl', [
    '--silent',
    '--show-error',
    '--max-time',
    '30',
    '--resolve',
    '${url.host}:${url.port}:${address.address}',
    '--write-out',
    '\n$statusMarker%{http_code}',
    url.toString(),
  ]).timeout(const Duration(seconds: 35));
  if (result.exitCode != 0) {
    throw StateError('curl exited ${result.exitCode}: ${result.stderr}');
  }
  final output = result.stdout as String;
  final markerOffset = output.lastIndexOf(statusMarker);
  if (markerOffset < 0) {
    throw StateError('curl output did not include a status marker: $output');
  }
  return (
    statusCode: int.parse(
      output.substring(markerOffset + statusMarker.length).trim(),
    ),
    body: output.substring(0, markerOffset).trimRight(),
  );
}
