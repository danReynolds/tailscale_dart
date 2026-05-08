import 'dart:async';

import 'package:shelf/shelf.dart' as shelf;
import 'package:tailscale/tailscale.dart';

/// Context key for the local tailnet endpoint on an adapted Shelf request.
const tailscaleShelfLocalEndpointKey = 'tailscale.local';

/// Context key for the remote tailnet endpoint on an adapted Shelf request.
const tailscaleShelfRemoteEndpointKey = 'tailscale.remote';

/// Context key for the original [TailscaleHttpRequest].
const tailscaleShelfRequestKey = 'tailscale.request';

/// Example extension that adapts package-native tailnet HTTP to Shelf.
///
/// This lives in `example/` instead of `lib/` so `package:tailscale` does not
/// take a core dependency on Shelf. Copy this extension into an application if
/// you want Shelf middleware and routing on top of [Http.bind].
extension TailscaleShelfHttp on Http {
  /// Binds a tailnet HTTP port and serves requests with a Shelf [handler].
  Future<TailscaleHttpServer> bindShelf({
    required int port,
    required shelf.Handler handler,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final server = await bind(port: port);
    final subscription = server.requests.listen(
      (request) {
        unawaited(_handleShelfRequest(request, handler, onError));
      },
      onError: (Object error, StackTrace stackTrace) {
        onError?.call(error, stackTrace);
      },
    );
    unawaited(server.done.whenComplete(() => subscription.cancel()));
    return server;
  }
}

/// Small app-style example that uses the extension above.
Future<TailscaleHttpServer> startShelfExample(Tailscale tailscale) {
  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addHandler((request) async {
    final remote =
        request.context[tailscaleShelfRemoteEndpointKey] as TailscaleEndpoint;
    if (request.url.path == 'echo' && request.method == 'POST') {
      final body = await request.readAsString();
      return shelf.Response.ok(
        'echo from ${remote.address}: $body',
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    }
    return shelf.Response.ok(
      'private over tailnet',
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );
  });

  return tailscale.http.bindShelf(port: 8080, handler: handler);
}

Future<void> _handleShelfRequest(
  TailscaleHttpRequest request,
  shelf.Handler handler,
  void Function(Object error, StackTrace stackTrace)? onError,
) async {
  try {
    final shelfRequest = shelf.Request(
      request.method,
      _requestedUri(request),
      protocolVersion: _protocolVersion(request.protocolVersion),
      headers: _requestHeaders(request),
      body: request.body,
      context: {
        tailscaleShelfLocalEndpointKey: request.local,
        tailscaleShelfRemoteEndpointKey: request.remote,
        tailscaleShelfRequestKey: request,
      },
    );

    final shelfResponse = await handler(shelfRequest);
    request.response.statusCode = shelfResponse.statusCode;
    _copyResponseHeaders(request.response, shelfResponse);
    await request.response.writeAll(shelfResponse.read(), close: true);
  } catch (error, stackTrace) {
    onError?.call(error, stackTrace);
    await _tryInternalServerError(request);
  }
}

Map<String, Object> _requestHeaders(TailscaleHttpRequest request) => {
      for (final entry in request.headersAll.entries)
        if (entry.value.length == 1)
          entry.key: entry.value.single
        else if (entry.value.length > 1)
          entry.key: List<String>.unmodifiable(entry.value),
    };

Uri _requestedUri(TailscaleHttpRequest request) {
  if (request.uri.hasScheme) return request.uri;
  final authority = request.host.trim().isEmpty
      ? _endpointAuthority(request.local)
      : request.host.trim();
  final originForm = request.requestUri.isEmpty
      ? '/'
      : request.requestUri.startsWith('/')
          ? request.requestUri
          : '/${request.requestUri}';
  return Uri.parse('http://$authority$originForm');
}

String _endpointAuthority(TailscaleEndpoint endpoint) {
  final address =
      endpoint.address.contains(':') && !endpoint.address.startsWith('[')
          ? '[${endpoint.address}]'
          : endpoint.address;
  return '$address:${endpoint.port}';
}

String _protocolVersion(String proto) =>
    proto.startsWith('HTTP/') ? proto.substring(5) : proto;

void _copyResponseHeaders(
  TailscaleHttpResponse target,
  shelf.Response source,
) {
  for (final entry in source.headersAll.entries) {
    final values = entry.value;
    if (values.isEmpty) continue;
    target.setHeader(entry.key, values.first);
    for (final value in values.skip(1)) {
      target.addHeader(entry.key, value);
    }
  }
}

Future<void> _tryInternalServerError(TailscaleHttpRequest request) async {
  try {
    await request.respond(
      statusCode: 500,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: 'Internal Server Error',
    );
  } catch (_) {
    // The response may already be committed if the handler failed mid-stream.
  }
}
