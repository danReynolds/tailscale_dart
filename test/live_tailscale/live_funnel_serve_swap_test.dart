/// Serve and Funnel on the same port and path are ONE publication.
///
/// This is the shape `tailscale funnel` has: upstream's CLI runs the same code
/// for serve and funnel, with Funnel as a boolean argument
/// (`cmd/tailscale/cli/serve_v2.go`, setServe). So calling `funnel.forward` on a
/// port you already serve does not create a second, competing handler — it
/// replaces the handler and turns on public ingress for that host:port.
///
/// This file was originally the reproduction for issue #87, where
/// `funnel.forward` destroyed the Serve mount (`tsnet.Up` clears the persisted
/// serve config on first run) and a Funnel publication answered only the public
/// internet. Measured live before the fix, in-tailnet access went
/// 200 -> EOF -> connection refused across the swap. It is kept as the
/// regression test for the aligned behavior.
///
/// The two backends return different bodies, so one fetch shows which handler
/// is live. Under the aligned model the later call owns the port+path, and both
/// vantages reach it.
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
      'live Tailscale Serve/Funnel swap',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-swap-$suffix';
  final peerHostname = 'dune-live-swap-peer-$suffix';

  LiveTailscaleApi? api;
  Tailscale? tsnet;
  String? stateDir;
  String? peerStateDir;
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
    for (final dir in [stateDir, peerStateDir]) {
      try {
        if (dir != null) Directory(dir).deleteSync(recursive: true);
      } catch (_) {}
    }
    api?.close();
  });

  test(
    'swapping serve.forward for funnel.forward: tailnet reachability and Serve survival',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateDir = Directory.systemTemp
          .createTempSync('tailscale_live_swap_')
          .path;
      peerStateDir = Directory.systemTemp
          .createTempSync('tailscale_live_swap_peer_')
          .path;
      // Auth keys are minted non-reusable (support/tailscale_api.dart), so the
      // in-tailnet client needs its own. Both fetches share one key and one
      // state dir: the second `up()` reconnects from the persisted identity.
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
      final fqdn = domains.first;
      final url = Uri.https(fqdn, '/');

      // Two distinguishable backends, so a single in-tailnet fetch tells us
      // which publication answered.
      final serveBackend = await _loopbackServer('hello from serve');
      final funnelBackend = await _loopbackServer('hello from funnel');

      try {
        // ---- Phase 1: what the reporter had working -----------------------
        final servePublication = await tsnet!.serve.forward(
          tailnetPort: 443,
          localAddress: InternetAddress.loopbackIPv4.address,
          localPort: serveBackend.port,
        );

        final beforeSwap = await _fetchFromTailnet(
          stateDir: peerStateDir!,
          hostname: peerHostname,
          authKey: peerAuthKey,
          controlUrl: controlUrl,
          url: url,
        );
        try {
          deviceIdsToDelete.add(
            (await api!.waitForDevice(hostname: peerHostname)).id,
          );
        } catch (_) {}
        expect(
          beforeSwap.error,
          isNull,
          reason:
              'Baseline failed: serve.forward is not reachable in-tailnet, so '
              'nothing after this point is interpretable.',
        );
        expect(beforeSwap.body, 'hello from serve');

        // ---- Phase 2: the swap --------------------------------------------
        final funnelPublication = await tsnet!.funnel.forward(
          publicPort: 443,
          localAddress: InternetAddress.loopbackIPv4.address,
          localPort: funnelBackend.port,
        );

        // Public vantage: this is the path live_funnel_forward_test.dart
        // already covers, repeated here so a failure distinguishes "Funnel is
        // broken" from "Funnel is fine but the tailnet vantage is not".
        final addresses = await _waitForPublicDns(fqdn);
        final publicFetch = await _waitForPublicFetch(url, addresses);

        // Tailnet vantage after the swap: the discriminator.
        final afterSwap = await _fetchFromTailnet(
          stateDir: peerStateDir!,
          hostname: peerHostname,
          authKey: peerAuthKey,
          controlUrl: controlUrl,
          url: url,
        );

        // ---- Phase 3: clearing the (single) publication --------------------
        // Serve and Funnel are one entry now, so closing the Funnel handle
        // removes the publication outright rather than revealing a second one
        // underneath. Before the rework this probe is what separated the two
        // #87 defects: "connection refused" meant tsnet.Up had destroyed the
        // serve config, "hello from serve" meant it was merely shadowed.
        await funnelPublication.close();
        final afterFunnelClose = await _fetchFromTailnet(
          stateDir: peerStateDir!,
          hostname: peerHostname,
          authKey: peerAuthKey,
          controlUrl: controlUrl,
          url: url,
        );

        String render(({int? statusCode, String body, String? error}) r) =>
            r.error ?? '${r.statusCode} ${r.body}';
        final report =
            'TAILNET (serve only)     : ${render(beforeSwap)}\n'
            'TAILNET (after funnel)   : ${render(afterSwap)}\n'
            'PUBLIC  (after funnel)   : ${publicFetch.statusCode} ${publicFetch.body}\n'
            'TAILNET (funnel cleared) : ${render(afterFunnelClose)}';
        printOnFailure(report);
        stdout.writeln(report);

        // Both vantages now reach the publication, which is the whole point of
        // matching `tailscale funnel`: before the rework the tailnet side was
        // reset and only the public side answered (issue #87).
        expect(
          publicFetch.statusCode,
          200,
          reason: 'Funnel must still answer public traffic.',
        );
        expect(publicFetch.body, 'hello from funnel');

        expect(
          afterSwap.error,
          isNull,
          reason:
              'A Funnel publication must be reachable from inside the tailnet, '
              'matching `tailscale funnel`. This is the #87 regression.',
        );

        // One entry, last write wins: funnel.forward targeted the same
        // host:port:mount as serve.forward, so it replaced that handler rather
        // than creating a second one competing for the port. Upstream behaves
        // the same way — serve and funnel are the same config entry.
        expect(
          afterSwap.body,
          'hello from funnel',
          reason:
              'serve.forward and funnel.forward on the same port and path are '
              'one publication; the later call owns the handler.',
        );

        // And clearing it removes that one entry — there is no separate Serve
        // mount left behind, because there never were two.
        expect(
          afterFunnelClose.error,
          isNotNull,
          reason:
              'Clearing the publication should remove the handler for this '
              'port and path entirely.',
        );

        await servePublication.close();
      } finally {
        await serveBackend.close(force: true);
        await funnelBackend.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<HttpServer> _loopbackServer(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      request.response.headers.contentType = ContentType.text;
      request.response.write(body);
      await request.response.close();
    }
  }().catchError((_) {}));
  return server;
}

/// Fetches [url] from a second node joined to the same tailnet, so the request
/// travels the tailnet path rather than the public internet.
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
    'tailnet before Funnel or Serve on 443 can work.',
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
    'Funnel URL $url did not become publicly reachable: ${lastErrors.join('; ')}',
  );
}

Future<List<InternetAddress>> _waitForPublicDns(String host) async {
  // Resolve through DNS-over-HTTPS rather than the local resolver: on a machine
  // that is itself on the tailnet, MagicDNS answers with the node's 100.x
  // address, which is exactly the confusion this test exists to characterize.
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
  throw StateError('Funnel hostname $host did not appear in public DNS: $lastError');
}

Future<List<InternetAddress>> _publicDnsRecords(String host, String type) async {
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
  final out = result.stdout as String;
  final markerOffset = out.lastIndexOf(statusMarker);
  if (markerOffset < 0) {
    throw StateError('curl output did not include a status marker: $out');
  }
  return (
    statusCode: int.parse(
      out.substring(markerOffset + statusMarker.length).trim(),
    ),
    body: out.substring(0, markerOffset).trimRight(),
  );
}
