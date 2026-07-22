// Audit experiment: does an oversized-but-legal UDP datagram kill the whole
// binding on macOS/iOS?
//
// Reproduces production exactly: go/udp_fd_posix.go newDatagramSocketPair
// creates the SOCK_DGRAM pair with NO buffer tuning (unlike TCP's
// newSocketPairConn). The public API (lib/src/api/udp.dart) accepts payloads
// up to udpMaxPayloadBytes = 60 KiB. On macOS the default AF_UNIX/DGRAM
// SO_SNDBUF caps a single datagram at ~2 KiB, so the reactor's write(2) of a
// larger envelope returns EMSGSIZE, which the reactor treats as a hard write
// error and tears the transport down.
//
// This drives the real PosixFdTransport (the reactor write path) exactly as a
// UDP send would, over an UNTUNED datagram socketpair, and reports the
// datagram size at which the transport dies.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _afUnix = 1;
const _sockDgram = 2;

typedef _SocketPairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairD = int Function(int, int, int, Pointer<Int32>);

final _lib = DynamicLibrary.process();
final _socketpair = _lib.lookupFunction<_SocketPairC, _SocketPairD>(
  'socketpair',
);

(int, int) _dgramPairUntuned() {
  // Exactly what go/udp_fd_posix.go newDatagramSocketPair does: no setsockopt.
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

Future<void> main() async {
  ensurePosixFdTransportAvailable();
  print('platform: ${Platform.operatingSystem}');
  print('Sending datagrams of increasing size through the reactor write path '
      'over an UNTUNED datagram socketpair (production config).');
  print('EMSGSIZE fires on the reactor write(2) into the socketpair, before '
      'the peer ever reads, so no reader is needed:');

  for (final size in [1024, 2048, 4096, 8192, 16384, 32768, 60 * 1024]) {
    final (dartSide, peerSide) = _dgramPairUntuned();
    final transport = await PosixFdTransport.adopt(dartSide);
    // Observe done so its error (if the transport dies) is surfaced here and
    // not as an uncaught zone error.
    Object? doneError;
    unawaited(transport.done.then((_) {}, onError: (Object e) => doneError = e));
    final datagram = Uint8List(size);
    var outcome = 'delivered (buffered in socketpair)';
    try {
      await transport.write(datagram).timeout(const Duration(seconds: 3));
    } on Object catch (e) {
      outcome = 'WRITE FAILED: ${e.toString().split("\n").first}';
    }
    // Let any transport-death event propagate.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (doneError != null) {
      outcome = 'TRANSPORT KILLED: ${doneError.toString().split("\n").first}';
    }
    print('  datagram $size bytes -> $outcome');
    await transport.close();
    closePosixFdForCleanup(peerSide);
  }
}
