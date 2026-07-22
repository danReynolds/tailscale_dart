// Audit experiment: cost of one duneReactorWake (kevent/eventfd syscall from
// the main isolate). Every PosixFdTransport.write()/command send pays exactly
// one of these; the benchmark README names "wake coalescing" as a likely
// optimization, so measure what a wake actually costs before designing one.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:tailscale/src/ffi_bindings.dart';
import 'package:tailscale/src/fd_transport.dart';

void main() {
  ensurePosixFdTransportAvailable();
  final handle = duneReactorCreate();
  if (handle < 0) throw StateError('reactor create failed');
  const n = 200000;
  // Warmup.
  for (var i = 0; i < 1000; i++) {
    duneReactorWake(handle);
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    duneReactorWake(handle);
  }
  sw.stop();
  print(
    'duneReactorWake: ${(sw.elapsedMicroseconds * 1000 / n).toStringAsFixed(0)}'
    ' ns/call ($n calls, coalesced by EV_CLEAR kernel-side)',
  );
  duneReactorClose(handle);
}
