@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/fd_transport.dart';
import 'package:tailscale/src/http_fd_client.dart';
import 'package:test/test.dart';

import 'support/posix_fd_test_support.dart';

void main() {
  test('parses response head and body bytes from the same fd chunk', () async {
    final (:leftFd, :rightFd) = socketPair(sockStream);
    final transport = await PosixFdTransport.adopt(leftFd);
    addTearDown(transport.close);

    final requestBodyDone = Completer<void>();
    final request = http.Request('GET', Uri.parse('http://100.64.0.2/hello'));
    final responseFuture = parseHttpFdResponseForTesting(
      responseTransport: transport,
      request: request,
      requestBodyDone: requestBodyDone.future,
    );

    final body = utf8.encode('hello tailnet');
    expect(
      TestPosixBindings.instance.write(
        rightFd,
        Uint8List.fromList(<int>[..._responseHead(), ...body]),
      ),
      isPositive,
    );
    TestPosixBindings.instance.close(rightFd);
    requestBodyDone.complete();

    final response = await responseFuture.timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);
    expect(
      await response.stream.bytesToString().timeout(const Duration(seconds: 5)),
      'hello tailnet',
    );
  });

  test('fails if response fd closes before a response head', () async {
    final (:leftFd, :rightFd) = socketPair(sockStream);
    final transport = await PosixFdTransport.adopt(leftFd);
    addTearDown(transport.close);

    final requestBodyDone = Completer<void>();
    final request = http.Request('GET', Uri.parse('http://100.64.0.2/closed'));
    final responseFuture = parseHttpFdResponseForTesting(
      responseTransport: transport,
      request: request,
      requestBodyDone: requestBodyDone.future,
    );

    TestPosixBindings.instance.close(rightFd);
    requestBodyDone.complete();

    await expectLater(
      responseFuture.timeout(const Duration(seconds: 5)),
      throwsA(
        isA<TailscaleHttpException>().having(
          (error) => error.message,
          'message',
          contains('closed before header'),
        ),
      ),
    );
  });

  test('fails invalid response head lengths', () async {
    final (:leftFd, :rightFd) = socketPair(sockStream);
    final transport = await PosixFdTransport.adopt(leftFd);
    addTearDown(transport.close);

    final requestBodyDone = Completer<void>();
    final request = http.Request('GET', Uri.parse('http://100.64.0.2/bad'));
    final responseFuture = parseHttpFdResponseForTesting(
      responseTransport: transport,
      request: request,
      requestBodyDone: requestBodyDone.future,
    );

    TestPosixBindings.instance.write(rightFd, Uint8List(4));
    TestPosixBindings.instance.close(rightFd);
    requestBodyDone.complete();

    await expectLater(
      responseFuture.timeout(const Duration(seconds: 5)),
      throwsA(
        isA<TailscaleHttpException>().having(
          (error) => error.message,
          'message',
          contains('Invalid HTTP response head length'),
        ),
      ),
    );
  });

  test('surfaces native response-head errors as ClientException', () async {
    final (:leftFd, :rightFd) = socketPair(sockStream);
    final transport = await PosixFdTransport.adopt(leftFd);
    addTearDown(transport.close);

    final requestBodyDone = Completer<void>();
    final request = http.Request('GET', Uri.parse('http://100.64.0.2/error'));
    final responseFuture = parseHttpFdResponseForTesting(
      responseTransport: transport,
      request: request,
      requestBodyDone: requestBodyDone.future,
    );

    TestPosixBindings.instance.write(
      rightFd,
      _responseHead(<String, Object?>{'error': 'dial refused'}),
    );
    TestPosixBindings.instance.close(rightFd);
    requestBodyDone.complete();

    await expectLater(
      responseFuture.timeout(const Duration(seconds: 5)),
      throwsA(
        isA<http.ClientException>()
            .having((error) => error.message, 'message', contains('refused'))
            .having((error) => error.uri, 'uri', request.url),
      ),
    );
  });

  test('late request body error is surfaced on response body stream', () async {
    final (:leftFd, :rightFd) = socketPair(sockStream);
    final transport = await PosixFdTransport.adopt(leftFd);
    addTearDown(transport.close);

    final requestBodyDone = Completer<void>();
    final request = http.Request('POST', Uri.parse('http://100.64.0.2/upload'));
    final responseFuture = parseHttpFdResponseForTesting(
      responseTransport: transport,
      request: request,
      requestBodyDone: requestBodyDone.future,
    );

    expect(
      TestPosixBindings.instance.write(rightFd, _responseHead()),
      isPositive,
    );
    TestPosixBindings.instance.close(rightFd);

    final response = await responseFuture.timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);

    requestBodyDone.completeError(
      StateError('upload failed'),
      StackTrace.current,
    );

    await expectLater(
      response.stream.drain<void>(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('upload failed'),
        ),
      ),
    );
  });

  test(
    'response body waits for request body completion before closing',
    () async {
      final (:leftFd, :rightFd) = socketPair(sockStream);
      final transport = await PosixFdTransport.adopt(leftFd);
      addTearDown(transport.close);

      final requestBodyDone = Completer<void>();
      final request = http.Request(
        'POST',
        Uri.parse('http://100.64.0.2/upload'),
      );
      final responseFuture = parseHttpFdResponseForTesting(
        responseTransport: transport,
        request: request,
        requestBodyDone: requestBodyDone.future,
      );

      expect(
        TestPosixBindings.instance.write(rightFd, _responseHead()),
        isPositive,
      );
      TestPosixBindings.instance.close(rightFd);

      final response = await responseFuture.timeout(const Duration(seconds: 5));
      final drained = Completer<void>();
      unawaited(response.stream.drain<void>().then((_) => drained.complete()));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(drained.isCompleted, isFalse);

      requestBodyDone.complete();
      await drained.future.timeout(const Duration(seconds: 5));
    },
  );
}

Uint8List _responseHead([Map<String, Object?>? fields]) {
  final payload = utf8.encode(
    jsonEncode(
      fields ??
          <String, Object?>{
            'statusCode': 200,
            'headers': <String, List<String>>{},
          },
    ),
  );
  final bytes = Uint8List(4 + payload.length);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, payload.length, Endian.big);
  bytes.setRange(4, bytes.length, payload);
  return bytes;
}
