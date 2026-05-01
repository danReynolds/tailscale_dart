/// Live Tailscale validation for routing controls that Headscale cannot prove.
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
///     dart test test/live_tailscale/live_routing_controls_test.dart
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
import '../e2e/support/peer_process.dart';
import '../e2e/support/state_waiters.dart';

const _defaultRoutes = ['0.0.0.0/0', '::/0'];

void main() {
  final apiKey = Platform.environment['TAILSCALE_API_KEY'];
  final tailnetId = Platform.environment['TAILSCALE_TAILNET_ID'];
  final controlUrl = Platform.environment['TAILSCALE_CONTROL_URL'];

  if (apiKey == null ||
      apiKey.isEmpty ||
      tailnetId == null ||
      tailnetId.isEmpty) {
    test(
      'live Tailscale routing controls',
      () {},
      skip: 'TAILSCALE_API_KEY and TAILSCALE_TAILNET_ID are required.',
    );
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final clientHostname = 'dune-live-client-$suffix';
  final exitHostname = 'dune-live-exit-$suffix';

  _TailscaleApi? api;
  Tailscale? tsnet;
  String? clientStateDir;
  String? exitStateDir;
  PeerProcess? exitPeer;
  final deviceIdsToDelete = <String>{};

  Uri? controlUri() {
    if (controlUrl == null || controlUrl.isEmpty) return null;
    return Uri.parse(controlUrl);
  }

  tearDownAll(() async {
    try {
      await tsnet?.exitNode.clear();
    } catch (_) {}
    try {
      await tsnet?.down();
    } catch (_) {}
    try {
      await exitPeer?.shutdown();
    } catch (_) {}
    for (final id in deviceIdsToDelete) {
      try {
        await api?.deleteDevice(id);
      } catch (_) {}
    }
    try {
      final dir = clientStateDir;
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final dir = exitStateDir;
      if (dir != null) Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    api?.close();
  });

  test(
    'exit node suggest, pinned use, auto use, and clear work on live Tailscale',
    () async {
      await _setUpLiveTailnet(
        apiKey: apiKey,
        tailnetId: tailnetId,
        clientHostname: clientHostname,
        exitHostname: exitHostname,
        controlUri: controlUri,
        onApi: (created) => api = created,
        onClientStateDir: (created) => clientStateDir = created,
        onExitStateDir: (created) => exitStateDir = created,
        onTailscale: (created) => tsnet = created,
        onExitPeer: (created) => exitPeer = created,
        deviceIdsToDelete: deviceIdsToDelete,
      );

      final liveTailscale = tsnet!;
      final candidate = await _waitForNode(
        liveTailscale,
        exitPeer!.ipv4,
        (node) => node.exitNodeOption,
        reason: 'exit peer did not become an eligible exit node',
      );

      final suggested = await _waitForSuggestedExitNode(liveTailscale);
      expect(
        suggested.exitNodeOption,
        isTrue,
        reason: 'suggest() must resolve to an eligible exit node',
      );

      await liveTailscale.exitNode.use(candidate);
      await _waitForCurrentExitNode(liveTailscale, candidate.stableNodeId);

      await liveTailscale.exitNode.clear();
      await _waitForNoExitNode(liveTailscale);

      await liveTailscale.exitNode.useAuto();
      final autoPrefs = await liveTailscale.prefs.get();
      expect(autoPrefs.autoExitNode, isTrue);
      await _waitForAnyCurrentExitNode(liveTailscale);

      await liveTailscale.exitNode.clear();
      await _waitForNoExitNode(liveTailscale);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _setUpLiveTailnet({
  required String apiKey,
  required String tailnetId,
  required String clientHostname,
  required String exitHostname,
  required Uri? Function() controlUri,
  required void Function(_TailscaleApi api) onApi,
  required void Function(String stateDir) onClientStateDir,
  required void Function(String stateDir) onExitStateDir,
  required void Function(Tailscale tailscale) onTailscale,
  required void Function(PeerProcess peer) onExitPeer,
  required Set<String> deviceIdsToDelete,
}) async {
  await warmUpNativeAssetForPeerSubprocesses();
  await detachLoadedNativeAssetForPeerSubprocesses();

  final api = _TailscaleApi(apiKey: apiKey, tailnetId: tailnetId);
  onApi(api);
  final clientStateDir = Directory.systemTemp
      .createTempSync('tailscale_live_client_')
      .path;
  final exitStateDir = Directory.systemTemp
      .createTempSync('tailscale_live_exit_')
      .path;
  onClientStateDir(clientStateDir);
  onExitStateDir(exitStateDir);

  final clientAuthKey = await api.createAuthKey();
  final exitAuthKey = await api.createAuthKey();

  Tailscale.init(stateDir: clientStateDir);
  final tsnet = Tailscale.instance;
  onTailscale(tsnet);
  await recordUntil(
    tsnet,
    NodeState.running,
    () => tsnet.up(
      hostname: clientHostname,
      authKey: clientAuthKey,
      controlUrl: controlUri(),
      timeout: const Duration(seconds: 120),
    ),
  );

  final exitPeer = await PeerProcess.spawn(
    stateDir: exitStateDir,
    controlUrl: controlUri()?.toString(),
    authKey: exitAuthKey,
    hostname: exitHostname,
    advertisedRoutes: _defaultRoutes,
  );
  onExitPeer(exitPeer);

  final clientDevice = await api.waitForDevice(
    hostname: clientHostname,
    ipv4: (await tsnet.status()).ipv4,
  );
  final exitDevice = await api.waitForDevice(
    hostname: exitHostname,
    ipv4: exitPeer.ipv4,
  );
  deviceIdsToDelete
    ..add(clientDevice.id)
    ..add(exitDevice.id);

  await api.enableRoutes(exitDevice.id, _defaultRoutes);
  await api.waitForRoutesEnabled(exitDevice.id, _defaultRoutes);
}

Future<TailscaleNode> _waitForNode(
  Tailscale tsnet,
  String ipv4,
  bool Function(TailscaleNode node) predicate, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  TailscaleNode? last;
  while (DateTime.now().isBefore(deadline)) {
    for (final node in await tsnet.nodes()) {
      if (node.tailscaleIPs.contains(ipv4)) {
        last = node;
        if (predicate(node)) return node;
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('$reason. Last observed node: $last');
}

Future<TailscaleNode> _waitForSuggestedExitNode(Tailscale tsnet) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final node = await tsnet.exitNode.suggest();
      if (node != null) return node;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('exitNode.suggest() did not return a node. Last error: $lastError');
}

Future<TailscaleNode> _waitForCurrentExitNode(
  Tailscale tsnet,
  String stableNodeId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  TailscaleNode? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await tsnet.exitNode.current();
    if (last?.stableNodeId == stableNodeId) return last!;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  fail('current exit node never became $stableNodeId. Last observed: $last');
}

Future<TailscaleNode> _waitForAnyCurrentExitNode(Tailscale tsnet) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  TailscaleNode? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await tsnet.exitNode.current();
    if (last != null) return last;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('auto exit-node mode did not select a current node. Last: $last');
}

Future<void> _waitForNoExitNode(Tailscale tsnet) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  TailscaleNode? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await tsnet.exitNode.current();
    if (last == null) return;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  fail('exit node did not clear. Last observed: $last');
}

final class _TailscaleApi {
  _TailscaleApi({required String apiKey, required this.tailnetId})
    : _client = http.Client(),
      _authHeader = 'Basic ${base64Encode(utf8.encode('$apiKey:'))}';

  final http.Client _client;
  final String tailnetId;
  final String _authHeader;

  void close() => _client.close();

  Future<String> createAuthKey() async {
    final decoded = await _requestJson(
      'POST',
      Uri.https('api.tailscale.com', '/api/v2/tailnet/$tailnetId/keys'),
      body: {
        'capabilities': {
          'devices': {
            'create': {
              'reusable': false,
              'ephemeral': true,
              'preauthorized': true,
            },
          },
        },
        'expirySeconds': 3600,
      },
    );
    final key = decoded['key'];
    if (key is! String || key.isEmpty) {
      throw StateError('Tailscale API did not return an auth key.');
    }
    return key;
  }

  Future<_ApiDevice> waitForDevice({
    required String hostname,
    String? ipv4,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final devices = await listDevices();
      for (final device in devices) {
        if (device.matches(hostname: hostname, ipv4: ipv4)) return device;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('Tailscale API did not list device $hostname.');
  }

  Future<List<_ApiDevice>> listDevices() async {
    final decoded = await _requestJson(
      'GET',
      Uri.https('api.tailscale.com', '/api/v2/tailnet/$tailnetId/devices', {
        'fields': 'all',
      }),
    );
    final devices = decoded['devices'];
    if (devices is! List) {
      throw StateError('Tailscale API device list response was malformed.');
    }
    return [
      for (final device in devices)
        if (device is Map<String, Object?>) _ApiDevice.fromJson(device),
    ];
  }

  Future<void> enableRoutes(String deviceId, List<String> routes) async {
    await _requestJson(
      'POST',
      Uri.https('api.tailscale.com', '/api/v2/device/$deviceId/routes'),
      body: {'routes': routes},
    );
  }

  Future<void> waitForRoutesEnabled(
    String deviceId,
    List<String> routes,
  ) async {
    final expected = routes.toSet();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final decoded = await _requestJson(
        'GET',
        Uri.https('api.tailscale.com', '/api/v2/device/$deviceId/routes'),
      );
      final enabled = (decoded['enabledRoutes'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      if (enabled.containsAll(expected)) return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('Tailscale API did not enable routes $routes.');
  }

  Future<void> deleteDevice(String deviceId) async {
    await _request(
      'DELETE',
      Uri.https('api.tailscale.com', '/api/v2/device/$deviceId'),
    );
  }

  Future<Map<String, Object?>> _requestJson(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
  }) async {
    final response = await _request(method, uri, body: body);
    if (response.body.isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, Object?>) return decoded;
    throw StateError('Tailscale API returned non-object JSON.');
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, uri)
      ..headers['Authorization'] = _authHeader
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Tailscale API $method ${uri.path} failed with HTTP '
        '${response.statusCode}: ${response.body}',
      );
    }
    return response;
  }
}

final class _ApiDevice {
  const _ApiDevice({
    required this.id,
    required this.name,
    required this.hostname,
    required this.addresses,
  });

  factory _ApiDevice.fromJson(Map<String, Object?> json) => _ApiDevice(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    hostname: json['hostname'] as String? ?? '',
    addresses: (json['addresses'] as List? ?? const [])
        .whereType<String>()
        .toList(),
  );

  final String id;
  final String name;
  final String hostname;
  final List<String> addresses;

  bool matches({required String hostname, String? ipv4}) {
    if (id.isEmpty) return false;
    if (ipv4 != null && addresses.contains(ipv4)) return true;
    final expected = hostname.toLowerCase();
    return this.hostname.toLowerCase() == expected ||
        name.toLowerCase() == expected ||
        name.toLowerCase().startsWith('$expected.');
  }
}
