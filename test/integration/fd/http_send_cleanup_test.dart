/// Fault-injection regression test for the HTTP client's fd-cleanup path: when
/// a step in the send pipeline throws after the native fds are handed over
/// (here `request.finalize()`), both fds must be released — otherwise the fd
/// leaks and the Go request goroutine pins forever. Drives the fd-owning core
/// (`_sendOverFds`) directly via its test seam on socketpair fds, and observes
/// closure as EOF on the peer ends.
@TestOn('mac-os || linux')
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:tailscale/src/fd_transport.dart';
import 'package:tailscale/src/http_fd_client.dart';
import 'package:test/test.dart';

import '../support/posix_fd_test_support.dart';

/// A request whose `finalize()` throws — the "re-sent or custom request" case
/// that must not leak the already-handed-over fds.
class _ThrowingFinalizeRequest extends http.BaseRequest {
  _ThrowingFinalizeRequest()
    : super('GET', Uri.parse('http://100.64.0.2/whatever'));

  @override
  http.ByteStream finalize() {
    super.finalize();
    throw StateError('finalize boom');
  }
}

void main() {
  test('send releases both fds when finalize() throws', () async {
    final reqPair = socketPair(sockStream);
    final respPair = socketPair(sockStream);

    // Peer ends: adopt so we can observe EOF when the client closes its ends.
    final reqPeer = await PosixFdTransport.adopt(reqPair.rightFd);
    addTearDown(reqPeer.close);
    final respPeer = await PosixFdTransport.adopt(respPair.rightFd);
    addTearDown(respPeer.close);

    final reqPeerEof = Completer<void>();
    reqPeer.input.listen(
      (_) {},
      onDone: () => reqPeerEof.complete(),
      cancelOnError: true,
    );
    final respPeerEof = Completer<void>();
    respPeer.input.listen(
      (_) {},
      onDone: () => respPeerEof.complete(),
      cancelOnError: true,
    );

    // The core adopts respLeft, then request.finalize() throws before the
    // request fd is transferred — the cleanup path must close both client ends.
    await expectLater(
      sendOverFdsForTesting(
        requestBodyFd: reqPair.leftFd,
        responseBodyFd: respPair.leftFd,
        request: _ThrowingFinalizeRequest(),
      ),
      throwsA(isA<StateError>()),
    );

    // Both peers must observe EOF; a leaked (unclosed) client fd never delivers
    // it, so the corresponding wait times out and fails.
    await reqPeerEof.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('request fd leaked: peer never saw EOF'),
    );
    await respPeerEof.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('response fd leaked: peer never saw EOF'),
    );
  });
}
