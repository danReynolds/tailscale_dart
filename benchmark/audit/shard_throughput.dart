// Warmup-controlled throughput for N concurrent transports. Run this against a
// build with _reactorShardCount forced to 1, then the round-robin 2-shard
// build, to isolate the true sharding benefit (no fd-parity lever, no
// first-run warmup confound: a warmup pass precedes the measured median-of-5).
import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

const _chunk = 64 * 1024;
const _sockBuf = 256 * 1024;

typedef _SPC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SPD = int Function(int, int, int, Pointer<Int32>);
typedef _RwC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _RwD = int Function(int, Pointer<Uint8>, int);
typedef _OptC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>, Uint32);
typedef _OptD = int Function(int, int, int, Pointer<Int32>, int);

final _lib = DynamicLibrary.process();
final _socketpair = _lib.lookupFunction<_SPC, _SPD>('socketpair');
final _writeSy = _lib.lookupFunction<_RwC, _RwD>('write');
final _readSy = _lib.lookupFunction<_RwC, _RwD>('read');
final _setsockopt = _lib.lookupFunction<_OptC, _OptD>('setsockopt');

(int, int) _pair() {
  final fds = calloc<Int32>(2);
  try {
    if (_socketpair(1, 1, 0, fds) != 0) throw StateError('socketpair');
    final l = fds[0], r = fds[1];
    for (final fd in [l, r]) {
      final v = calloc<Int32>(1)..value = _sockBuf;
      final sol = Platform.isMacOS ? 0xffff : 1;
      _setsockopt(fd, sol, Platform.isMacOS ? 0x1001 : 7, v, 4);
      _setsockopt(fd, sol, Platform.isMacOS ? 0x1002 : 8, v, 4);
      calloc.free(v);
    }
    return (l, r);
  } finally {
    calloc.free(fds);
  }
}

void _peerReader(List<Object> a) {
  final done = a[0] as SendPort;
  final fd = a[1] as int;
  final buf = calloc<Uint8>(_chunk);
  var total = 0;
  while (true) {
    final n = _readSy(fd, buf, _chunk);
    if (n <= 0) break;
    total += n;
  }
  calloc.free(buf);
  done.send(total);
}

Future<void> _writeWindowed(PosixFdTransport t, int total) async {
  final chunk = Uint8List(_chunk);
  const window = 4 * 1024 * 1024;
  final inflight = Queue<Future<void>>();
  var out = 0, remaining = total;
  while (remaining > 0) {
    final n = remaining < _chunk ? remaining : _chunk;
    inflight.add(t.write(n == _chunk ? chunk : Uint8List.sublistView(chunk, 0, n)));
    out += n;
    remaining -= n;
    if (out >= window) {
      await inflight.removeFirst();
      out -= _chunk;
    }
  }
  await Future.wait(inflight);
  await t.closeWrite();
}

Future<double> _measureOutbound(int pairs, int bytesPer) async {
  final lefts = <int>[], rights = <int>[];
  for (var i = 0; i < pairs; i++) {
    final (l, r) = _pair();
    lefts.add(l);
    rights.add(r);
  }
  final transports = [
    for (final l in lefts)
      await PosixFdTransport.adopt(l,
          maxReadChunkSize: _chunk, maxPendingWriteBytes: 16 * 1024 * 1024),
  ];
  final done = ReceivePort();
  for (final r in rights) {
    await Isolate.spawn(_peerReader, <Object>[done.sendPort, r]);
  }
  final sw = Stopwatch()..start();
  await Future.wait([for (final t in transports) _writeWindowed(t, bytesPer)]);
  await done.take(pairs).toList();
  sw.stop();
  for (final t in transports) {
    await t.close();
  }
  for (final r in rights) {
    closePosixFdForCleanup(r);
  }
  return pairs * bytesPer / (1024 * 1024) / (sw.elapsedMicroseconds / 1e6);
}

Future<void> main(List<String> args) async {
  ensurePosixFdTransportAvailable();
  final pairs = args.isNotEmpty ? int.parse(args[0]) : 8;
  const bytesPer = 64 * 1024 * 1024;
  final load = await debugPosixFdReactorShardLoad();
  // Warmup (discarded).
  await _measureOutbound(pairs, bytesPer);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final samples = <double>[];
  for (var i = 0; i < 5; i++) {
    samples.add(await _measureOutbound(pairs, bytesPer));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  samples.sort();
  final active = await debugPosixFdReactorShardLoad();
  print('pairs=$pairs outbound MiB/s samples=${samples.map((s) => s.toStringAsFixed(0)).toList()}');
  print('median=${samples[2].toStringAsFixed(0)} MiB/s  '
      'shardLoad(initial=$load, active=$active)');
}
