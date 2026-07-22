// Audit experiment: does the process exit cleanly while reactor shard
// isolates are (a) idle-exited, (b) blocked in an infinite native wait with a
// live transport, or (c) leaked by a failed registration (the shard never arms
// its idle-exit because `sawTransport` never becomes true)?
//
// Run with: dart run --enable-experiment=native-assets \
//   benchmark/audit/exit_behavior.dart <clean|open|register-failure>
// and wrap in `timeout` to detect hangs.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/fd_transport.dart';

typedef _SocketPairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairD = int Function(int, int, int, Pointer<Int32>);

(int, int) _socketpair() {
  final lib = DynamicLibrary.process();
  final socketpair = lib.lookupFunction<_SocketPairC, _SocketPairD>(
    'socketpair',
  );
  final fds = calloc<Int32>(2);
  try {
    if (socketpair(1, 1, 0, fds) != 0) throw StateError('socketpair failed');
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

Future<void> main(List<String> args) async {
  ensurePosixFdTransportAvailable();
  switch (args.isEmpty ? 'clean' : args[0]) {
    case 'clean':
      final (left, right) = _socketpair();
      final transport = await PosixFdTransport.adopt(left);
      await transport.close();
      closePosixFdForCleanup(right);
      // Wait past the idle grace so the shard exits on its own.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      print('exiting-clean');
    case 'open':
      final (left, _) = _socketpair();
      final transport = await PosixFdTransport.adopt(left);
      transport.input.listen((_) {});
      print('exiting-open (transport still registered, reactor in wait)');
    case 'register-failure':
      // 4099 is (almost certainly) not an open descriptor; native registration
      // fails with EBADF, adopt throws, and the shard for 4099 % 2 == 1 never
      // arms its idle exit.
      try {
        await PosixFdTransport.adopt(4099);
        print('UNEXPECTED: adopt succeeded');
      } on Object catch (error) {
        print('adopt failed as expected: $error');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      print('exiting-register-failure (shard leaked?)');
    default:
      stderr.writeln('unknown mode');
      exitCode = 2;
  }
}
