// Audit experiment: datagram integrity through the fd reactor.
//
// Hypotheses under test:
//  H1 (reactor truncation): the reactor clamps read(2) length by remaining
//     inbound credit (`availableInbound`) and its per-iteration budget. On a
//     SOCK_DGRAM socketpair a short read TRUNCATES the datagram and discards
//     the tail — and the UDP envelope has no length field, so the truncated
//     datagram decodes as valid-with-short-payload. Two back-to-back 61699-byte
//     datagrams against maxInboundQueuedBytes=100000 should deterministically
//     deliver [61699, 38301].
//  H2 (platform buffer limits): go/udp_fd_posix.go newDatagramSocketPair never
//     enlarges the socketpair buffers (TCP's newSocketPairConn does). Check
//     what the OS default allows for a single datagram write.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _afUnix = 1;
const _sockDgram = 2;
const _envelopeBytes = 4 + 255 + 60 * 1024; // udpMaxEnvelopeBytes = 61699

typedef _SocketPairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairD = int Function(int, int, int, Pointer<Int32>);
typedef _RwC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _RwD = int Function(int, Pointer<Uint8>, int);
typedef _SetsockoptC =
    Int32 Function(Int32, Int32, Int32, Pointer<Int32>, Uint32);
typedef _SetsockoptD = int Function(int, int, int, Pointer<Int32>, int);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

final _lib = DynamicLibrary.process();
final _socketpair = _lib.lookupFunction<_SocketPairC, _SocketPairD>(
  'socketpair',
);
final _write = _lib.lookupFunction<_RwC, _RwD>('write');
final _setsockopt = _lib.lookupFunction<_SetsockoptC, _SetsockoptD>(
  'setsockopt',
);
final _errnoLoc = _lib.lookupFunction<_ErrnoC, _ErrnoD>(
  Platform.isMacOS ? '__error' : '__errno_location',
);

(int, int) _dgramPair() {
  final fds = calloc<Int32>(2);
  try {
    if (_socketpair(_afUnix, _sockDgram, 0, fds) != 0) {
      throw StateError('socketpair failed');
    }
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

void _tune(int fd, int bytes) {
  final solSocket = Platform.isMacOS ? 0xffff : 1;
  final soSndbuf = Platform.isMacOS ? 0x1001 : 7;
  final soRcvbuf = Platform.isMacOS ? 0x1002 : 8;
  final v = calloc<Int32>(1)..value = bytes;
  _setsockopt(fd, solSocket, soSndbuf, v, 4);
  _setsockopt(fd, solSocket, soRcvbuf, v, 4);
  calloc.free(v);
}

int _writeDatagram(int fd, int size) {
  final buf = calloc<Uint8>(size);
  for (var i = 0; i < size; i++) {
    buf[i] = i & 0xff;
  }
  final n = _write(fd, buf, size);
  final errno = n < 0 ? _errnoLoc().value : 0;
  calloc.free(buf);
  return n < 0 ? -errno : n;
}

Future<void> main() async {
  ensurePosixFdTransportAvailable();

  // --- H2: what datagram size fits the DEFAULT socketpair buffers?
  {
    final (a, b) = _dgramPair();
    stdout.write('H2 default-buffer max datagram: ');
    var largest = 0;
    for (final size in [1024, 2048, 4096, 8192, 16384, 32768, _envelopeBytes]) {
      final n = _writeDatagram(a, size);
      if (n == size) {
        largest = size;
      } else {
        print('write($size) -> $n (largest ok: $largest)');
        break;
      }
    }
    closePosixFdForCleanup(a);
    closePosixFdForCleanup(b);
  }

  // --- H1: reactor truncation under inbound-credit clamp.
  {
    final (dartSide, peerSide) = _dgramPair();
    _tune(dartSide, 512 * 1024);
    _tune(peerSide, 512 * 1024);
    final transport = await PosixFdTransport.adopt(
      dartSide,
      maxReadChunkSize: 64 * 1024,
      maxInboundQueuedBytes: 100000,
    );
    final sizes = <int>[];
    final done = Completer<void>();
    transport.input.listen(
      (chunk) {
        sizes.add(chunk.length);
        if (sizes.length == 2) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    // Two max-size datagrams, queued back-to-back before the reactor drains.
    final w1 = _writeDatagram(peerSide, _envelopeBytes);
    final w2 = _writeDatagram(peerSide, _envelopeBytes);
    print('H1 peer wrote datagrams: $w1, $w2 (expected $_envelopeBytes each)');
    await done.future.timeout(const Duration(seconds: 5));
    print(
      'H1 dart received datagram sizes: $sizes '
      '(truncation if any != $_envelopeBytes)',
    );
    await transport.close();
    closePosixFdForCleanup(peerSide);
  }
}
