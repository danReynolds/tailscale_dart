import 'dart:convert';

import 'package:http/http.dart' as http;

final class DemoAuthKeyRequest {
  const DemoAuthKeyRequest({
    required this.apiKey,
    required this.tailnetId,
    this.reusable = false,
    this.ephemeral = false,
    this.preauthorized = true,
    this.expiry = const Duration(days: 1),
    this.tags = const [],
  });

  final String apiKey;
  final String tailnetId;
  final bool reusable;
  final bool ephemeral;
  final bool preauthorized;
  final Duration expiry;
  final List<String> tags;
}

final class DemoGeneratedAuthKey {
  const DemoGeneratedAuthKey({required this.key, this.id, this.expires});

  final String key;
  final String? id;
  final DateTime? expires;
}

final class DemoAuthKeyException implements Exception {
  const DemoAuthKeyException(this.message);

  final String message;

  @override
  String toString() => 'DemoAuthKeyException: $message';
}

Future<DemoGeneratedAuthKey> createDemoAuthKey(
  DemoAuthKeyRequest request, {
  http.Client? client,
}) async {
  final apiKey = request.apiKey.trim();
  final tailnetId = request.tailnetId.trim();
  if (apiKey.isEmpty) {
    throw const DemoAuthKeyException('Tailscale API key is required.');
  }
  if (tailnetId.isEmpty) {
    throw const DemoAuthKeyException('Tailnet ID is required.');
  }
  if (tailnetId.contains('/')) {
    throw const DemoAuthKeyException('Tailnet ID must not contain slashes.');
  }
  if (request.expiry <= Duration.zero) {
    throw const DemoAuthKeyException('Auth key expiry must be positive.');
  }

  final ownedClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient.post(
      Uri.https('api.tailscale.com', '/api/v2/tailnet/$tailnetId/keys'),
      headers: {
        'Authorization': _basicAuth(apiKey),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'capabilities': {
          'devices': {
            'create': {
              'reusable': request.reusable,
              'ephemeral': request.ephemeral,
              'preauthorized': request.preauthorized,
              if (request.tags.isNotEmpty) 'tags': request.tags,
            },
          },
        },
        'expirySeconds': request.expiry.inSeconds,
      }),
    );

    if (response.statusCode != 200) {
      throw DemoAuthKeyException(
        'Tailscale API returned HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw const DemoAuthKeyException(
        'Tailscale API returned an unexpected response.',
      );
    }
    final key = decoded['key'];
    if (key is! String || key.isEmpty) {
      throw const DemoAuthKeyException(
        'Tailscale API response did not include an auth key.',
      );
    }
    final id = decoded['id'];
    final expires = decoded['expires'];
    return DemoGeneratedAuthKey(
      key: key,
      id: id is String && id.isNotEmpty ? id : null,
      expires: expires is String ? DateTime.tryParse(expires) : null,
    );
  } finally {
    if (ownedClient) httpClient.close();
  }
}

String _basicAuth(String apiKey) =>
    'Basic ${base64Encode(utf8.encode('$apiKey:'))}';
