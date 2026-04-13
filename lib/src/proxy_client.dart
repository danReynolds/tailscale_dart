import 'package:http/http.dart' as http;

const proxyAuthHeader = 'X-Tailscale-Proxy-Token';

Uri buildProxyUri(int proxyPort, Uri targetUrl) {
  final sanitizedTarget = Uri.parse(targetUrl.toString().split('#').first);
  return Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: proxyPort,
    path: '/proxy',
    queryParameters: {'target': sanitizedTarget.toString()},
  );
}

final class PreparedProxyRequest {
  const PreparedProxyRequest({required this.request, required this.bodyDone});

  final http.StreamedRequest request;
  final Future<void> bodyDone;
}

PreparedProxyRequest prepareProxyRequest(
  int proxyPort,
  String proxyAuthToken,
  http.BaseRequest original,
) {
  final body = original.finalize();
  final proxied =
      http.StreamedRequest(
          original.method,
          buildProxyUri(proxyPort, original.url),
        )
        ..contentLength = original.contentLength
        ..followRedirects = original.followRedirects
        ..maxRedirects = original.maxRedirects
        ..persistentConnection = original.persistentConnection;

  proxied.headers.addAll(original.headers);
  proxied.headers[proxyAuthHeader] = proxyAuthToken;

  final bodyDone = () async {
    try {
      await proxied.sink.addStream(body);
    } finally {
      await proxied.sink.close();
    }
  }();

  return PreparedProxyRequest(request: proxied, bodyDone: bodyDone);
}

/// An HTTP client that routes requests through the Tailscale proxy.
class TailscaleProxyClient extends http.BaseClient {
  TailscaleProxyClient(
    this._proxyPort,
    this._proxyAuthToken, {
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  final int _proxyPort;
  final String _proxyAuthToken;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final prepared = prepareProxyRequest(_proxyPort, _proxyAuthToken, request);
    final responseFuture = _inner.send(prepared.request);
    try {
      await prepared.bodyDone;
    } catch (_) {
      try {
        await responseFuture;
      } catch (_) {}
      rethrow;
    }
    return responseFuture;
  }

  @override
  void close() => _inner.close();
}
