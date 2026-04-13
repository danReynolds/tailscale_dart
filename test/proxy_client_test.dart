import 'package:http/http.dart' as http;
import 'package:tailscale/src/proxy_client.dart';
import 'package:test/test.dart';

void main() {
  group('buildProxyUri', () {
    test('encodes the full target URL as a single query parameter', () {
      final target = Uri.parse(
        'https://100.64.0.5/api/data?target=user-value&foo=bar',
      );

      final proxyUri = buildProxyUri(4242, target);

      expect(proxyUri.scheme, 'http');
      expect(proxyUri.host, '127.0.0.1');
      expect(proxyUri.port, 4242);
      expect(proxyUri.path, '/proxy');
      expect(proxyUri.queryParameters, {'target': target.toString()});
    });
  });

  group('prepareProxyRequest', () {
    test('preserves multipart bodies and request metadata', () async {
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://100.64.0.5/upload?target=user-value&foo=bar'),
            )
            ..followRedirects = false
            ..maxRedirects = 7
            ..persistentConnection = false
            ..fields['note'] = 'hello'
            ..files.add(
              http.MultipartFile.fromString(
                'file',
                'payload',
                filename: 'payload.txt',
              ),
            );

      final prepared = prepareProxyRequest(9999, 'secret-token', request);
      final bodyFuture = prepared.request.finalize().bytesToString();
      await prepared.bodyDone;

      expect(
        prepared.request.url.queryParameters['target'],
        request.url.toString(),
      );
      expect(prepared.request.followRedirects, isFalse);
      expect(prepared.request.maxRedirects, 7);
      expect(prepared.request.persistentConnection, isFalse);
      expect(prepared.request.headers[proxyAuthHeader], 'secret-token');
      expect(
        prepared.request.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );

      final body = await bodyFuture;
      expect(body, contains('name="note"'));
      expect(body, contains('hello'));
      expect(body, contains('filename="payload.txt"'));
      expect(body, contains('payload'));
    });
  });
}
