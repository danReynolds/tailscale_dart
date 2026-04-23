import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tailscale/src/http_client.dart';
import 'package:test/test.dart';

void main() {
  group('TailscaleHttpClient', () {
    test('streams the request body and preserves request metadata', () async {
      late TailscaleHttpRequestHead captured;
      final sentChunks = <Uint8List>[];
      var bodyClosed = false;
      final bodyClosedCompleter = Completer<void>();
      final client = TailscaleHttpClient.internal(
        openRequest: (request) async {
          captured = request;
          return TailscaleHttpStream(
            responseHead: Future.value(
              TailscaleHttpResponseHead(
                statusCode: 200,
                headers: const <String, List<String>>{
                  'content-type': <String>['text/plain'],
                },
                contentLength: 2,
                isRedirect: false,
                finalUrl: Uri.parse('https://tailnet.example/echo'),
                reasonPhrase: 'OK',
                connectionClose: false,
              ),
            ),
            responseBody: Stream<Uint8List>.value(
              Uint8List.fromList(utf8.encode('ok')),
            ),
            sendBodyChunk: (bytes) async {
              sentChunks.add(Uint8List.fromList(bytes));
            },
            closeRequestBody: () async {
              bodyClosed = true;
              if (!bodyClosedCompleter.isCompleted) {
                bodyClosedCompleter.complete();
              }
            },
            cancel: () async {},
          );
        },
      );

      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://tailnet.example/upload?target=user-value'),
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

      final response = await client.send(request);
      expect(response.statusCode, 200);
      await bodyClosedCompleter.future;

      expect(captured.method, 'POST');
      expect(
        captured.url,
        Uri.parse('https://tailnet.example/upload?target=user-value'),
      );
      expect(captured.followRedirects, isFalse);
      expect(captured.maxRedirects, 7);
      expect(captured.persistentConnection, isFalse);
      expect(
        captured.headers['content-type']?.single,
        startsWith('multipart/form-data; boundary='),
      );

      final body = utf8.decode(sentChunks.expand((chunk) => chunk).toList());
      expect(body, contains('name="note"'));
      expect(body, contains('hello'));
      expect(body, contains('filename="payload.txt"'));
      expect(body, contains('payload'));
      expect(bodyClosed, isTrue);
    });

    test(
      'maps streamed response metadata onto a standard streamed response',
      () async {
        final client = TailscaleHttpClient.internal(
          openRequest: (_) async => TailscaleHttpStream(
            responseHead: Future.value(
              TailscaleHttpResponseHead(
                statusCode: 201,
                headers: const <String, List<String>>{
                  'set-cookie': <String>['a=1', 'b=2'],
                  'connection': <String>['close'],
                },
                contentLength: 7,
                isRedirect: false,
                finalUrl: Uri.parse('https://tailnet.example/resource'),
                reasonPhrase: 'Created',
                connectionClose: true,
              ),
            ),
            responseBody: Stream<Uint8List>.value(
              Uint8List.fromList(utf8.encode('created')),
            ),
            sendBodyChunk: (_) async {},
            closeRequestBody: () async {},
            cancel: () async {},
          ),
        );

        final request = http.Request(
          'POST',
          Uri.parse('https://tailnet.example/resource'),
        );

        final response = await client.send(request);
        expect(response.statusCode, 201);
        expect(response.headers['set-cookie'], 'a=1,b=2');
        expect(response.persistentConnection, isFalse);
        expect(await response.stream.bytesToString(), 'created');
      },
    );

    test('maps abortTrigger to request cancellation', () async {
      final abort = Completer<void>();
      var cancelled = false;
      final bodyController = StreamController<Uint8List>();
      final client = TailscaleHttpClient.internal(
        openRequest: (_) async => TailscaleHttpStream(
          responseHead: Future.value(
            TailscaleHttpResponseHead(
              statusCode: 200,
              headers: const <String, List<String>>{},
              contentLength: null,
              isRedirect: false,
              finalUrl: Uri.parse('https://tailnet.example/stream'),
              reasonPhrase: 'OK',
              connectionClose: false,
            ),
          ),
          responseBody: bodyController.stream,
          sendBodyChunk: (_) async {},
          closeRequestBody: () async {},
          cancel: () async {
            cancelled = true;
            await bodyController.close();
          },
        ),
      );

      final request = http.AbortableRequest(
        'GET',
        Uri.parse('https://tailnet.example/stream'),
        abortTrigger: abort.future,
      );

      final response = await client.send(request);
      final bytesFuture = response.stream.toBytes();
      abort.complete();

      await expectLater(
        bytesFuture,
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(cancelled, isTrue);
    });
  });
}
