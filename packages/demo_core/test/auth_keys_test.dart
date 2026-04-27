import 'package:demo_core/demo_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('createDemoAuthKey posts the Tailscale admin key request shape', () async {
    late Uri requestedUrl;
    late Map<String, String> requestedHeaders;
    late String requestedBody;

    final result = await createDemoAuthKey(
      const DemoAuthKeyRequest(
        apiKey: 'tskey-api-test',
        tailnetId: 'example.com',
        reusable: true,
        preauthorized: true,
        expiry: Duration(hours: 2),
      ),
      client: MockClient((request) async {
        requestedUrl = request.url;
        requestedHeaders = request.headers;
        requestedBody = request.body;
        return http.Response(
          '{"id":"k123","key":"tskey-auth-test","expires":"2026-04-24T00:00:00Z"}',
          200,
        );
      }),
    );

    expect(result.key, 'tskey-auth-test');
    expect(result.id, 'k123');
    expect(
      requestedUrl.toString(),
      'https://api.tailscale.com/api/v2/tailnet/example.com/keys',
    );
    expect(requestedHeaders['authorization'], startsWith('Basic '));
    expect(requestedHeaders['content-type'], 'application/json');
    expect(requestedBody, contains('"expirySeconds":7200'));
    expect(requestedBody, contains('"reusable":true'));
    expect(requestedBody, contains('"preauthorized":true'));
  });
}
