/// Regression test for the HTTP client request-body streaming contract
/// ("T2-c"): the request body must cross the Dart→Go fd incrementally as the
/// source produces it, never buffered in full before the first write. The Go
/// side already streams its end (the request fd is handed straight to
/// `http.NewRequest` as `req.Body`), so the only place buffering could be
/// reintroduced is the Dart writer — which is exactly what this pins.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tailscale/src/fd_transport.dart';
import 'package:tailscale/src/http_fd_client.dart';
import 'package:test/test.dart';

import '../support/posix_fd_test_support.dart';

void main() {
  test(
    'request body streams incrementally and does not buffer until source close',
    () async {
      final (:leftFd, :rightFd) = socketPair(sockStream);

      // Destination end of the socketpair: observe what the writer pushes
      // across the fd, in the order and timing it arrives.
      final destination = await PosixFdTransport.adopt(rightFd);
      addTearDown(destination.close);
      final received = BytesBuilder(copy: false);
      final firstChunkArrived = Completer<void>();
      final sub = destination.input.listen((chunk) {
        received.add(chunk);
        if (!firstChunkArrived.isCompleted) firstChunkArrived.complete();
      });
      addTearDown(sub.cancel);

      // Source body the writer consumes. Crucially we keep it OPEN after the
      // first chunk — a buffering writer (collect-all-then-write) would have
      // written nothing at all by this point.
      final source = StreamController<List<int>>();
      final writeDone = writeRequestBodyForTesting(source.stream, leftFd);

      source.add(Uint8List.fromList(utf8.encode('early-chunk')));

      // The discriminating assertion: the early chunk must reach the peer
      // BEFORE the source stream is closed. Under buffering this times out.
      await firstChunkArrived.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail(
          'request body was buffered, not streamed: no bytes crossed the fd '
          'before the source stream closed',
        ),
      );
      expect(utf8.decode(received.toBytes()), 'early-chunk');

      // A late chunk plus close must also stream through and terminate cleanly.
      source.add(Uint8List.fromList(utf8.encode('-late')));
      await source.close();
      await writeDone;

      // Let the trailing bytes drain to the destination before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(utf8.decode(received.toBytes()), 'early-chunk-late');
    },
  );
}
