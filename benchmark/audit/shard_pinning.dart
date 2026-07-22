// Audit experiment: reactor shard distribution under production-like fd
// handoff, and the throughput cost of shard pinning.
//
// Production (go/tcp_fd_posix.go newSocketPairConn) always hands Dart fds[0]
// of each socketpair; socketpair(2) allocates the two lowest free descriptor
// slots, so back-to-back connections tend to produce Dart-side fds of constant
// parity. The reactor assigns shards with `fd % shardCount` (shardCount = 2),
// so constant parity pins every transport to one shard.
//
// This script measures, with the peer end pumped by raw blocking syscalls in
// separate isolates (as Go's io.Copy pumps the tsnet side in production):
//   1. the natural shard distribution for fds[0]-only adoption
//   2. inbound (reactor read path) throughput: pinned vs forced-spread
//   3. outbound (reactor write path) throughput: pinned vs forced-spread
import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _afUnix = 1;
const _sockStream = 1;
const _shutWr = 1;
const _chunkBytes = 64 * 1024;
const _sockBufBytes = 256 * 1024; // matches go tuneSocketPairBuffers

final int _shardCount = math.max(1, math.min(Platform.numberOfProcessors, 2));

typedef _SocketPairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairD = int Function(int, int, int, Pointer<Int32>);
typedef _RwC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _RwD = int Function(int, Pointer<Uint8>, int);
typedef _CloseC = Int32 Function(Int32);
typedef _CloseD = int Function(int);
typedef _ShutdownC = Int32 Function(Int32, Int32);
typedef _ShutdownD = int Function(int, int);
typedef _DupC = Int32 Function(Int32);
typedef _DupD = int Function(int);
typedef _SetsockoptC =
    Int32 Function(Int32, Int32, Int32, Pointer<Int32>, Uint32);
typedef _SetsockoptD = int Function(int, int, int, Pointer<Int32>, int);

final class _Libc {
  _Libc._(DynamicLibrary lib)
    : socketpair = lib.lookupFunction<_SocketPairC, _SocketPairD>('socketpair'),
      write = lib.lookupFunction<_RwC, _RwD>('write'),
      read = lib.lookupFunction<_RwC, _RwD>('read'),
      close = lib.lookupFunction<_CloseC, _CloseD>('close'),
      shutdown = lib.lookupFunction<_ShutdownC, _ShutdownD>('shutdown'),
      dup = lib.lookupFunction<_DupC, _DupD>('dup'),
      setsockopt = lib.lookupFunction<_SetsockoptC, _SetsockoptD>('setsockopt');

  static final instance = _Libc._(DynamicLibrary.process());

  final _SocketPairD socketpair;
  final _RwD write;
  final _RwD read;
  final _CloseD close;
  final _ShutdownD shutdown;
  final _DupD dup;
  final _SetsockoptD setsockopt;
}

(int, int) _socketpair() {
  final fds = calloc<Int32>(2);
  try {
    if (_Libc.instance.socketpair(_afUnix, _sockStream, 0, fds) != 0) {
      throw StateError('socketpair failed');
    }
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

void _tuneBuffers(int fd) {
  final solSocket = Platform.isMacOS ? 0xffff : 1;
  final soSndbuf = Platform.isMacOS ? 0x1001 : 7;
  final soRcvbuf = Platform.isMacOS ? 0x1002 : 8;
  final value = calloc<Int32>(1)..value = _sockBufBytes;
  try {
    _Libc.instance.setsockopt(fd, solSocket, soSndbuf, value, 4);
    _Libc.instance.setsockopt(fd, solSocket, soRcvbuf, value, 4);
  } finally {
    calloc.free(value);
  }
}

/// Peer isolate: blocking-writes [total] bytes to [fd], then SHUT_WR.
void peerWriter(List<Object> args) {
  final done = args[0] as SendPort;
  final fd = args[1] as int;
  final total = args[2] as int;
  final buffer = calloc<Uint8>(_chunkBytes);
  var remaining = total;
  while (remaining > 0) {
    final n = _Libc.instance.write(
      fd,
      buffer,
      remaining < _chunkBytes ? remaining : _chunkBytes,
    );
    if (n <= 0) {
      calloc.free(buffer);
      done.send('peer write failed n=$n');
      return;
    }
    remaining -= n;
  }
  _Libc.instance.shutdown(fd, _shutWr);
  calloc.free(buffer);
  done.send('ok');
}

/// Peer isolate: blocking-reads from [fd] until EOF, reports total bytes.
void peerReader(List<Object> args) {
  final done = args[0] as SendPort;
  final fd = args[1] as int;
  final buffer = calloc<Uint8>(_chunkBytes);
  var total = 0;
  while (true) {
    final n = _Libc.instance.read(fd, buffer, _chunkBytes);
    if (n == 0) break;
    if (n < 0) {
      calloc.free(buffer);
      done.send('peer read failed n=$n');
      return;
    }
    total += n;
  }
  calloc.free(buffer);
  done.send(total);
}

Future<int> _drainUntilEof(Stream<Uint8List> input) async {
  var total = 0;
  await for (final chunk in input) {
    total += chunk.length;
  }
  return total;
}

Future<void> _writeWindowed(PosixFdTransport transport, int total) async {
  final chunk = Uint8List(_chunkBytes);
  const window = 4 * 1024 * 1024;
  final inflight = Queue<Future<void>>();
  var outstanding = 0;
  var remaining = total;
  while (remaining > 0) {
    final n = math.min(_chunkBytes, remaining);
    inflight.add(
      transport.write(
        n == _chunkBytes ? chunk : Uint8List.sublistView(chunk, 0, n),
      ),
    );
    outstanding += n;
    remaining -= n;
    if (outstanding >= window) {
      await inflight.removeFirst();
      outstanding -= _chunkBytes;
    }
  }
  await Future.wait(inflight);
  await transport.closeWrite();
}

final class _Setup {
  _Setup(this.lefts, this.rights, this.burned);
  final List<int> lefts;
  final List<int> rights;
  final List<int> burned;
}

/// Creates [pairs] socketpairs up front (contiguous fd allocation, as a
/// steady accept loop would see). When [spread] is set, burns one fd between
/// pairs so the Dart-side fd parity alternates.
_Setup _createPairs(int pairs, {required bool spread}) {
  final lefts = <int>[];
  final rights = <int>[];
  final burned = <int>[];
  for (var i = 0; i < pairs; i++) {
    final (left, right) = _socketpair();
    _tuneBuffers(left);
    _tuneBuffers(right);
    lefts.add(left);
    rights.add(right);
    if (spread) burned.add(_Libc.instance.dup(0));
  }
  return _Setup(lefts, rights, burned);
}

String _shardReport(List<int> fds) {
  final counts = <int, int>{};
  for (final fd in fds) {
    counts.update(fd % _shardCount, (n) => n + 1, ifAbsent: () => 1);
  }
  final dist = [
    for (var s = 0; s < _shardCount; s++) 'shard$s=${counts[s] ?? 0}',
  ].join(' ');
  return 'fds=$fds  $dist';
}

Future<double> _measureInbound({
  required int pairs,
  required bool spread,
  required int bytesPerPair,
}) async {
  final setup = _createPairs(pairs, spread: spread);
  print('  inbound ${spread ? "spread" : "pinned"}: '
      '${_shardReport(setup.lefts)}');
  final transports = <PosixFdTransport>[];
  for (final left in setup.lefts) {
    transports.add(
      await PosixFdTransport.adopt(left, maxReadChunkSize: _chunkBytes),
    );
  }
  final drains = [for (final t in transports) _drainUntilEof(t.input)];
  final done = ReceivePort();
  final sw = Stopwatch()..start();
  for (final right in setup.rights) {
    await Isolate.spawn(peerWriter, <Object>[
      done.sendPort,
      right,
      bytesPerPair,
    ]);
  }
  final totals = await Future.wait(drains);
  sw.stop();
  final peerResults = await done.take(pairs).toList();
  done.close();
  for (final t in transports) {
    await t.close();
  }
  for (final right in setup.rights) {
    _Libc.instance.close(right);
  }
  for (final b in setup.burned) {
    _Libc.instance.close(b);
  }
  for (final total in totals) {
    if (total != bytesPerPair) throw StateError('short drain: $total');
  }
  for (final r in peerResults) {
    if (r != 'ok') throw StateError('peer failure: $r');
  }
  final mib = pairs * bytesPerPair / (1024 * 1024);
  return mib / (sw.elapsedMicroseconds / 1e6);
}

Future<double> _measureOutbound({
  required int pairs,
  required bool spread,
  required int bytesPerPair,
}) async {
  final setup = _createPairs(pairs, spread: spread);
  print('  outbound ${spread ? "spread" : "pinned"}: '
      '${_shardReport(setup.lefts)}');
  final transports = <PosixFdTransport>[];
  for (final left in setup.lefts) {
    transports.add(
      await PosixFdTransport.adopt(
        left,
        maxReadChunkSize: _chunkBytes,
        maxPendingWriteBytes: 16 * 1024 * 1024,
      ),
    );
  }
  final done = ReceivePort();
  for (final right in setup.rights) {
    await Isolate.spawn(peerReader, <Object>[done.sendPort, right]);
  }
  final sw = Stopwatch()..start();
  await Future.wait([
    for (final t in transports) _writeWindowed(t, bytesPerPair),
  ]);
  final peerResults = await done.take(pairs).toList();
  sw.stop();
  done.close();
  for (final t in transports) {
    await t.close();
  }
  for (final right in setup.rights) {
    _Libc.instance.close(right);
  }
  for (final b in setup.burned) {
    _Libc.instance.close(b);
  }
  for (final r in peerResults) {
    if (r != bytesPerPair) throw StateError('peer drained $r');
  }
  final mib = pairs * bytesPerPair / (1024 * 1024);
  return mib / (sw.elapsedMicroseconds / 1e6);
}

Future<void> main(List<String> args) async {
  ensurePosixFdTransportAvailable();
  final pairs = args.isNotEmpty ? int.parse(args[0]) : 4;
  final mib = args.length > 1 ? int.parse(args[1]) : 128;
  final bytesPerPair = mib * 1024 * 1024;
  print('shardCount=$_shardCount pairs=$pairs payload=${mib}MiB/pair '
      'sockbuf=${_sockBufBytes ~/ 1024}KiB chunk=${_chunkBytes ~/ 1024}KiB');

  for (final direction in ['inbound', 'outbound']) {
    for (final spread in [false, true]) {
      var best = 0.0;
      for (var run = 0; run < 2; run++) {
        final mibs = direction == 'inbound'
            ? await _measureInbound(
                pairs: pairs,
                spread: spread,
                bytesPerPair: bytesPerPair,
              )
            : await _measureOutbound(
                pairs: pairs,
                spread: spread,
                bytesPerPair: bytesPerPair,
              );
        if (mibs > best) best = mibs;
      }
      print('$direction ${spread ? "spread" : "pinned"}: '
          '${best.toStringAsFixed(0)} MiB/s');
      // Let idle shards exit between conditions for a clean slate.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
}
