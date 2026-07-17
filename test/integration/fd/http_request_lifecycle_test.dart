@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tailscale/src/api/http.dart';
import 'package:tailscale/src/fd_transport.dart';
import 'package:test/test.dart';

import '../support/posix_fd_test_support.dart';

void main() {
  group('TailscaleHttpRequest fd lifecycle', () {
    test('respond closes an unread request body transport', () async {
      final (:requestPeer, :responsePeer, :responseSub, :request) =
          await _requestWithBody();
      addTearDown(() => _closePeers(requestPeer, responsePeer, responseSub));

      await request.respond(body: 'ok');

      await expectLater(
        requestPeer.input.isEmpty.timeout(const Duration(seconds: 5)),
        completion(isTrue),
      );
    });

    test(
      'direct response close closes an unread request body transport',
      () async {
        final (:requestPeer, :responsePeer, :responseSub, :request) =
            await _requestWithBody();
        addTearDown(() => _closePeers(requestPeer, responsePeer, responseSub));

        await request.response.close();

        await expectLater(
          requestPeer.input.isEmpty.timeout(const Duration(seconds: 5)),
          completion(isTrue),
        );
      },
    );

    test('serializes unawaited sequential writes in call order', () async {
      final responseBytes = <int>[];
      final (
        :requestPeer,
        :responsePeer,
        :responseSub,
        :request,
      ) = await _requestWithBody(
        onResponseChunk: (chunk) => responseBytes.addAll(chunk),
      );
      addTearDown(() => _closePeers(requestPeer, responsePeer, responseSub));

      // Fire-and-forget, IOSink-style. Without write serialization the first
      // write suspends on the head frame's ack while the second's bytes enqueue
      // ahead of it, producing wire order head, BBBB, AAAA.
      unawaited(request.response.write(utf8.encode('AAAA')));
      unawaited(request.response.write(utf8.encode('BBBB')));
      await request.response.close();
      await responseSub.asFuture<void>().timeout(const Duration(seconds: 5));

      final body = _responseBodyAfterHead(Uint8List.fromList(responseBytes));
      expect(utf8.decode(body), 'AAAABBBB');
    });

    test('respond closes transports even when the body write fails', () async {
      final (:requestPeer, :responsePeer, :responseSub, :request) =
          await _requestWithBody();
      addTearDown(() => _closePeers(requestPeer, responsePeer, responseSub));

      // Break the response path so the body write fails with EPIPE.
      await responseSub.cancel();
      await responsePeer.close();

      await expectLater(
        request.respond(body: 'payload').timeout(const Duration(seconds: 5)),
        throwsA(isA<Object>()),
      );

      // Despite the failed write, respond()'s finally still closed the response
      // (and via onClose the request transport), so the request peer sees EOF.
      await expectLater(
        requestPeer.input.isEmpty.timeout(const Duration(seconds: 5)),
        completion(isTrue),
      );
    });

    test('respond does not duplicate content-length by case', () async {
      final responseBytes = <int>[];
      final (
        :requestPeer,
        :responsePeer,
        :responseSub,
        :request,
      ) = await _requestWithBody(
        onResponseChunk: (chunk) => responseBytes.addAll(chunk),
      );
      addTearDown(() => _closePeers(requestPeer, responsePeer, responseSub));

      await request.respond(headers: {'Content-Length': '2'}, body: 'ok');
      await responseSub.asFuture<void>().timeout(const Duration(seconds: 5));

      final headers = _decodeResponseHeaders(Uint8List.fromList(responseBytes));
      final contentLengthHeaders = headers.keys
          .where((key) => key.toLowerCase() == 'content-length')
          .toList();
      expect(contentLengthHeaders, <String>['Content-Length']);
      expect(headers['Content-Length'], <Object?>['2']);
    });
  });
}

Future<
  ({
    PosixFdTransport requestPeer,
    PosixFdTransport responsePeer,
    StreamSubscription<Uint8List> responseSub,
    TailscaleHttpRequest request,
  })
>
_requestWithBody({void Function(Uint8List chunk)? onResponseChunk}) async {
  final (leftFd: requestLeftFd, rightFd: requestRightFd) = socketPair(
    sockStream,
  );
  final (leftFd: responseLeftFd, rightFd: responseRightFd) = socketPair(
    sockStream,
  );

  final requestTransport = await PosixFdTransport.adopt(requestLeftFd);
  PosixFdTransport? responseTransport;
  PosixFdTransport? requestPeer;
  PosixFdTransport? responsePeer;
  StreamSubscription<Uint8List>? responseSub;
  try {
    responseTransport = await PosixFdTransport.adopt(responseLeftFd);
    requestPeer = await PosixFdTransport.adopt(requestRightFd);
    responsePeer = await PosixFdTransport.adopt(responseRightFd);
    responseSub = responsePeer.input.listen(onResponseChunk ?? (_) {});
    return (
      requestPeer: requestPeer,
      responsePeer: responsePeer,
      responseSub: responseSub,
      request: createHttpRequestForTesting(
        requestTransport: requestTransport,
        responseTransport: responseTransport,
      ),
    );
  } catch (_) {
    await requestTransport.close();
    await responseTransport?.close();
    await responseSub?.cancel();
    await requestPeer?.close();
    await responsePeer?.close();
    if (responseTransport == null) {
      TestPosixBindings.instance.close(responseLeftFd);
    }
    if (requestPeer == null) {
      TestPosixBindings.instance.close(requestRightFd);
    }
    if (responsePeer == null) {
      TestPosixBindings.instance.close(responseRightFd);
    }
    rethrow;
  }
}

Map<String, Object?> _decodeResponseHeaders(Uint8List bytes) {
  final headLength = ByteData.sublistView(bytes).getUint32(0, Endian.big);
  final head = jsonDecode(utf8.decode(bytes.sublist(4, 4 + headLength)));
  return ((head as Map<String, dynamic>)['headers'] as Map).cast();
}

Uint8List _responseBodyAfterHead(Uint8List bytes) {
  final headLength = ByteData.sublistView(bytes).getUint32(0, Endian.big);
  return Uint8List.sublistView(bytes, 4 + headLength);
}

Future<void> _closePeers(
  PosixFdTransport requestPeer,
  PosixFdTransport responsePeer,
  StreamSubscription<Uint8List> responseSub,
) async {
  await responseSub.cancel();
  await Future.wait(<Future<void>>[requestPeer.close(), responsePeer.close()]);
}
