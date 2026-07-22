// Audit check: does round-robin shard assignment distribute constant-parity
// (production-shaped) fds across shards, where `fd % shardCount` pinned them?
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

typedef _SocketPairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairD = int Function(int, int, int, Pointer<Int32>);

final _socketpair = DynamicLibrary.process()
    .lookupFunction<_SocketPairC, _SocketPairD>('socketpair');

(int, int) _pair() {
  final fds = calloc<Int32>(2);
  try {
    if (_socketpair(1, 1, 0, fds) != 0) throw StateError('socketpair failed');
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

Future<void> main() async {
  ensurePosixFdTransportAvailable();
  final shardCount = math.max(1, math.min(Platform.numberOfProcessors, 2));

  // Adopt 8 receivers with production-shaped constant-parity fds (fds[0] of
  // each socketpair, created back-to-back → all even, spaced two apart).
  final transports = <PosixFdTransport>[];
  final peers = <int>[];
  final adoptedFds = <int>[];
  for (var i = 0; i < 8; i++) {
    final (left, right) = _pair();
    peers.add(right);
    adoptedFds.add(left);
    transports.add(await PosixFdTransport.adopt(left));
  }

  final oldAssignment = <int, int>{};
  for (final fd in adoptedFds) {
    oldAssignment.update(fd % shardCount, (n) => n + 1, ifAbsent: () => 1);
  }

  final load = await debugPosixFdReactorShardLoad();
  print('shardCount=$shardCount adopted fds=$adoptedFds');
  print('OLD (fd % shardCount) would give: $oldAssignment');
  print('NEW (round-robin) actual shard load: $load');
  print('active shards used: ${load.length} of $shardCount');

  for (final t in transports) {
    await t.close();
  }
  for (final fd in peers) {
    closePosixFdForCleanup(fd);
  }
}
