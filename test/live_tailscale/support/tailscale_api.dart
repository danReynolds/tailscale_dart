import 'dart:convert';

import 'package:http/http.dart' as http;

final class LiveTailscaleApi {
  LiveTailscaleApi({required String apiKey, required this.tailnetId})
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

  Future<LiveTailscaleDevice> waitForDevice({
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

  Future<List<LiveTailscaleDevice>> listDevices() async {
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
        if (device is Map<String, Object?>)
          LiveTailscaleDevice.fromJson(device),
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

final class LiveTailscaleDevice {
  const LiveTailscaleDevice({
    required this.id,
    required this.name,
    required this.hostname,
    required this.addresses,
  });

  factory LiveTailscaleDevice.fromJson(Map<String, Object?> json) =>
      LiveTailscaleDevice(
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
