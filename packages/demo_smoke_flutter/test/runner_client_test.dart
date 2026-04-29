import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dune_smoke_flutter/src/runner_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetchSmokeConfig parses config and sends runner token', () async {
    final server = await _TestServer.start((request) async {
      expect(request.uri.path, '/config');
      expect(request.uri.queryParameters['session'], 'macos');
      expect(request.headers.value(smokeRunnerTokenHeader), 'secret');
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'controlUrl': 'http://localhost:18080',
            'authKey': 'auth',
            'targetIp': '100.64.0.1',
            'hostname': 'dune-smoke-macos',
            'stateSuffix': 'macos-1',
          }),
        );
      await request.response.close();
    });
    addTearDown(server.close);

    final config = await fetchSmokeConfig(
      runnerUrl: server.url,
      session: 'macos',
      token: 'secret',
    );

    expect(config.controlUrl, 'http://localhost:18080');
    expect(config.authKey, 'auth');
    expect(config.targetIp, '100.64.0.1');
    expect(config.hostname, 'dune-smoke-macos');
    expect(config.stateSuffix, 'macos-1');
  });

  test('fetchSmokeConfig rejects non-200 responses', () async {
    final server = await _TestServer.start((request) async {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    addTearDown(server.close);

    expect(
      fetchSmokeConfig(
        runnerUrl: server.url,
        session: 'macos',
        token: 'secret',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('HTTP 401'),
        ),
      ),
    );
  });

  test('fetchSmokeConfig rejects missing required fields', () async {
    final server = await _TestServer.start((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'controlUrl': 'http://localhost:18080'}));
      await request.response.close();
    });
    addTearDown(server.close);

    expect(
      fetchSmokeConfig(
        runnerUrl: server.url,
        session: 'macos',
        token: 'secret',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('authKey'),
        ),
      ),
    );
  });

  test('postSmokeResult sends token and JSON body', () async {
    final bodyCompleter = Completer<Map<String, Object?>>();
    final server = await _TestServer.start((request) async {
      expect(request.uri.path, '/result');
      expect(request.uri.queryParameters['session'], 'android');
      expect(request.headers.value(smokeRunnerTokenHeader), 'secret');
      final raw = await utf8.decoder.bind(request).join();
      bodyCompleter.complete(jsonDecode(raw) as Map<String, Object?>);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    addTearDown(server.close);

    await postSmokeResult(
      runnerUrl: server.url,
      session: 'android',
      token: 'secret',
      result: {'ok': true, 'durationMs': 12},
    );

    expect(await bodyCompleter.future, {'ok': true, 'durationMs': 12});
  });

  test('postSmokeResult times out when runner does not respond', () async {
    final server = await _TestServer.start((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    addTearDown(server.close);

    expect(
      postSmokeResult(
        runnerUrl: server.url,
        session: 'android',
        token: 'secret',
        result: {'ok': true},
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}

final class _TestServer {
  const _TestServer._(this._server);

  final HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_TestServer> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        try {
          await handler(request);
        } catch (error) {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write(error.toString());
          await request.response.close();
        }
      }),
    );
    return _TestServer._(server);
  }

  Future<void> close() => _server.close(force: true);
}
