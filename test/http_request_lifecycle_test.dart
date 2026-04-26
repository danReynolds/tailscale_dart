@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:tailscale/src/api/http.dart';
import 'package:tailscale/src/fd_transport.dart';
import 'package:test/test.dart';

import 'support/posix_fd_test_support.dart';

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
_requestWithBody() async {
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
    responseSub = responsePeer.input.listen((_) {});
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

Future<void> _closePeers(
  PosixFdTransport requestPeer,
  PosixFdTransport responsePeer,
  StreamSubscription<Uint8List> responseSub,
) async {
  await responseSub.cancel();
  await Future.wait(<Future<void>>[requestPeer.close(), responsePeer.close()]);
}
