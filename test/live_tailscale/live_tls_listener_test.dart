/// Live Tailscale validation for HTTPS/TLS behavior Headscale cannot prove.
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
///     dart test test/live_tailscale/live_tls_listener_test.dart
@TestOn('mac-os || linux')
@Tags(['live-tailscale'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
      'live Tailscale TLS listener',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final hostname = 'dune-live-tls-$suffix';

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
    'tls.bind serves HTTPS with an auto-provisioned Tailscale certificate',
    () async {
      await warmUpNativeAssetForPeerSubprocesses();

      api = LiveTailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
      stateDir = Directory.systemTemp
          .createTempSync('tailscale_live_tls_')
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
      final server = await tsnet!.tls.bind(port: 443);
      addTearDown(server.close);

      final handled = _serveOnePlaintextHttpRequest(server);
      final response = await tsnet!.http.client
          .get(Uri.https(domains.first, '/live-tls'))
          .timeout(const Duration(seconds: 45));

      expect(response.statusCode, 200);
      expect(response.body, 'hello from tls');
      await handled.timeout(const Duration(seconds: 15));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
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

Future<void> _serveOnePlaintextHttpRequest(TailscaleListener server) async {
  final conn = await server.connections.first.timeout(
    const Duration(seconds: 45),
  );
  try {
    await _readHttpRequestHead(conn.input);
    await conn.output.write(
      ascii.encode(
        'HTTP/1.1 200 OK\r\n'
        'content-length: 14\r\n'
        'content-type: text/plain\r\n'
        'connection: close\r\n'
        '\r\n'
        'hello from tls',
      ),
    );
    await conn.output.close();
  } finally {
    await conn.close();
  }
}

Future<void> _readHttpRequestHead(Stream<Uint8List> input) async {
  final buffer = BytesBuilder();
  await for (final chunk in input.timeout(
    const Duration(seconds: 15),
    onTimeout: (sink) => sink.close(),
  )) {
    buffer.add(chunk);
    if (ascii
        .decode(buffer.toBytes(), allowInvalid: true)
        .contains('\r\n\r\n')) {
      return;
    }
  }
  fail('TLS listener did not receive a complete HTTP request head.');
}
