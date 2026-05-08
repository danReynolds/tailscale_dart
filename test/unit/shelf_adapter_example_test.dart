import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

import '../../example/shelf_adapter.dart';

void main() {
  group('Shelf adapter example', () {
    test('bindShelf adapts request metadata, body, and context', () async {
      final http = _FakeHttp();
      late shelf.Request seen;

      await http.bindShelf(
        port: 8080,
        handler: (request) async {
          seen = request;
          final body = await request.readAsString();
          return shelf.Response(
            201,
            headers: {
              'content-type': 'text/plain',
              'set-cookie': ['a=1', 'b=2'],
            },
            body: 'echo: $body',
          );
        },
      );

      final request = _FakeRequest(
        method: 'POST',
        requestUri: '/echo?source=test',
        host: 'private.tailnet:8080',
        headersAll: {
          'content-type': ['text/plain; charset=utf-8'],
          'x-request-id': ['abc'],
          'x-multi': ['one', 'two'],
        },
        body: 'hello',
      );
      http.add(request);
      await request.response.done.timeout(const Duration(seconds: 1));

      expect(http.boundPort, 8080);
      expect(seen.method, 'POST');
      expect(
        seen.requestedUri,
        Uri.parse('http://private.tailnet:8080/echo?source=test'),
      );
      expect(seen.url.path, 'echo');
      expect(seen.url.query, 'source=test');
      expect(seen.protocolVersion, '1.1');
      expect(seen.headers['x-request-id'], 'abc');
      expect(seen.headersAll['x-multi'], ['one', 'two']);
      expect(
        seen.context[tailscaleShelfRemoteEndpointKey],
        const TailscaleEndpoint(address: '100.64.0.2', port: 12345),
      );
      expect(seen.context[tailscaleShelfRequestKey], same(request));
      expect(request.response.statusCode, 201);
      expect(request.response.headersAll['set-cookie'], ['a=1', 'b=2']);
      expect(request.response.textBody, 'echo: hello');
    });

    test('bindShelf supports streamed Shelf response bodies', () async {
      final http = _FakeHttp();
      await http.bindShelf(
        port: 80,
        handler: (_) => shelf.Response.ok(
          Stream<List<int>>.fromIterable([
            utf8.encode('chunk-1'),
            utf8.encode(':chunk-2'),
          ]),
          headers: {'content-type': 'text/plain'},
        ),
      );

      final request = _FakeRequest();
      http.add(request);
      await request.response.done.timeout(const Duration(seconds: 1));

      expect(request.response.statusCode, 200);
      expect(request.response.textBody, 'chunk-1:chunk-2');
      expect(request.response.headers['content-type'], 'text/plain');
    });

    test('bindShelf reports handler errors and sends a 500', () async {
      final http = _FakeHttp();
      Object? reportedError;
      StackTrace? reportedStack;

      await http.bindShelf(
        port: 80,
        handler: (_) => throw StateError('boom'),
        onError: (error, stackTrace) {
          reportedError = error;
          reportedStack = stackTrace;
        },
      );

      final request = _FakeRequest();
      http.add(request);
      await request.response.done.timeout(const Duration(seconds: 1));

      expect(reportedError, isA<StateError>());
      expect(reportedStack, isNotNull);
      expect(request.response.statusCode, 500);
      expect(
        request.response.headers['content-type'],
        'text/plain; charset=utf-8',
      );
      expect(request.response.textBody, 'Internal Server Error');
    });

    test(
      'bindShelf cancels the request subscription when the server finishes',
      () async {
        final http = _FakeHttp();
        var handled = false;
        final server = await http.bindShelf(
          port: 80,
          handler: (_) {
            handled = true;
            return shelf.Response.ok('ok');
          },
        );

        http.server.completeDone();
        await server.done.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);

        expect(http.server.cancelCount, 1);

        http.add(_FakeRequest());
        await Future<void>.delayed(Duration.zero);

        expect(handled, isFalse);
        await http.server.close();
      },
    );
  });
}

final class _FakeHttp implements Http {
  _FakeHttp() : server = _FakeHttpServer();

  final _FakeHttpServer server;
  int? boundPort;

  @override
  Future<TailscaleHttpServer> bind({required int port}) async {
    boundPort = port;
    return server;
  }

  void add(TailscaleHttpRequest request) => server.add(request);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHttpServer implements TailscaleHttpServer {
  _FakeHttpServer() : _controller = StreamController<TailscaleHttpRequest>() {
    _controller.onCancel = () {
      cancelCount += 1;
    };
  }

  final StreamController<TailscaleHttpRequest> _controller;
  final _done = Completer<void>();
  var cancelCount = 0;

  void add(TailscaleHttpRequest request) => _controller.add(request);

  void completeDone() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  TailscaleEndpoint get tailnet =>
      const TailscaleEndpoint(address: '100.64.0.1', port: 80);

  @override
  Stream<TailscaleHttpRequest> get requests => _controller.stream;

  @override
  Future<void> close() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}

final class _FakeRequest implements TailscaleHttpRequest {
  _FakeRequest({
    this.method = 'GET',
    this.requestUri = '/',
    this.host = 'private.tailnet',
    this.headersAll = const {},
    String body = '',
  }) : response = _FakeResponse(),
       headers = Map.unmodifiable({
         for (final entry in headersAll.entries)
           if (entry.value.isNotEmpty) entry.key: entry.value.join(', '),
       }),
       uri = Uri.parse(requestUri.isEmpty ? '/' : requestUri),
       _bodyBytes = Uint8List.fromList(utf8.encode(body));

  final Uint8List _bodyBytes;

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final String requestUri;

  @override
  final String host;

  @override
  final String protocolVersion = 'HTTP/1.1';

  @override
  final Map<String, String> headers;

  @override
  final Map<String, List<String>> headersAll;

  @override
  final int? contentLength = null;

  @override
  final TailscaleEndpoint local = const TailscaleEndpoint(
    address: '100.64.0.1',
    port: 80,
  );

  @override
  final TailscaleEndpoint remote = const TailscaleEndpoint(
    address: '100.64.0.2',
    port: 12345,
  );

  @override
  final _FakeResponse response;

  @override
  Stream<Uint8List> get body => Stream.value(_bodyBytes);

  @override
  Future<void> respond({
    int statusCode = 200,
    Map<String, String>? headers,
    Object? body,
  }) async {
    response.statusCode = statusCode;
    headers?.forEach(response.setHeader);
    switch (body) {
      case null:
        break;
      case String text:
        await response.write(utf8.encode(text));
      case List<int> bytes:
        await response.write(bytes);
      case Stream<List<int>> chunks:
        await response.writeAll(chunks);
      default:
        await response.write(utf8.encode(body.toString()));
    }
    await response.close();
  }
}

final class _FakeResponse implements TailscaleHttpResponse {
  final _headers = <String, String>{};
  final _extraHeaderValues = <String, List<String>>{};
  final _body = <int>[];
  final _done = Completer<void>();
  var _statusCode = 200;

  String get textBody => utf8.decode(_body);

  @override
  int get statusCode => _statusCode;

  @override
  set statusCode(int value) {
    _statusCode = value;
  }

  @override
  Map<String, String> get headers => _headers;

  @override
  Map<String, List<String>> get headersAll => {
    for (final entry in _headers.entries)
      entry.key: [entry.value, ...?_extraHeaderValues[entry.key]],
  };

  @override
  void setHeader(String name, String value) {
    _headers[name] = value;
    _extraHeaderValues.remove(name);
  }

  @override
  void addHeader(String name, String value) {
    if (!_headers.containsKey(name)) {
      _headers[name] = value;
      return;
    }
    (_extraHeaderValues[name] ??= <String>[]).add(value);
  }

  @override
  Future<void> write(List<int> bytes) async {
    _body.addAll(bytes);
  }

  @override
  Future<void> writeString(String text, {Encoding encoding = utf8}) async {
    _body.addAll(encoding.encode(text));
  }

  @override
  Future<void> writeAll(Stream<List<int>> chunks, {bool close = false}) async {
    await for (final chunk in chunks) {
      await write(chunk);
    }
    if (close) await this.close();
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}
