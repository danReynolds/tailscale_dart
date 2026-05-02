/// Live Tailscale validation for public Funnel forwarding behavior Headscale
/// cannot prove.
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
///     dart test test/live_tailscale/live_funnel_forward_test.dart
@TestOn('mac-os || linux')
@Tags(['live-tailscale'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
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
      'live Tailscale Funnel forwarding',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-funnel-$suffix';

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  String? stateDir;
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
    api?.close();
  });

  test(
    'funnel.forward proxies public HTTPS traffic to a loopback HTTP server',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateDir = Directory.systemTemp
          .createTempSync('tailscale_live_funnel_')
          .path;
      final authKey = await api!.createAuthKey();

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

      final publication = await tsnet!.funnel.forward(
        localPort: localServer.port,
      );
      try {
        final url = Uri.https(domains.first, '/live-funnel');
        final addresses = await _waitForPublicDns(url.host);
        final response = await _waitForPublicFetch(url, addresses);

        expect(publication.url.toString(), 'https://${domains.first}/');
        expect(publication.funnel, isTrue);
        expect(response.statusCode, 200);
        expect(response.body, 'hello from funnel');
      } finally {
        await publication.close();
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
    request.response.write('hello from funnel');
    await request.response.close();
  }
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
          '${address.address}: HTTP ${response.statusCode}: '
          '${response.body}',
        );
      } catch (error) {
        errors.add('${address.address}: $error');
      }
    }
    lastErrors = errors;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError(
    'Funnel URL $url did not become reachable before public DNS/proxy '
    'propagation timed out: ${lastErrors.join('; ')}',
  );
}

Future<List<InternetAddress>> _waitForPublicDns(String host) async {
  // Avoid querying the target hostname through the local resolver until public
  // DNS exists. macOS can negatively cache the initial NXDOMAIN and mask later
  // Funnel propagation.
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      // Prefer IPv4 when available. Some developer networks publish IPv6 DNS
      // but do not have a working IPv6 route, which can mask the real Funnel
      // readiness signal behind local ENETUNREACH failures.
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
  final statusMarker = '__DUNE_STATUS__:';
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
  final stdout = result.stdout as String;
  final markerOffset = stdout.lastIndexOf(statusMarker);
  if (markerOffset < 0) {
    throw StateError('curl output did not include a status marker: $stdout');
  }
  final body = stdout.substring(0, markerOffset).trimRight();
  final statusCode = int.parse(
    stdout.substring(markerOffset + statusMarker.length).trim(),
  );
  return (statusCode: statusCode, body: body);
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
