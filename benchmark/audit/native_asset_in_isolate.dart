// Make-or-break for the helper-isolate design: do the tailscale `@Native`
// bindings (the native ASSET, libtailscale — not libc) resolve and run inside
// a spawned/Isolate.run isolate? If @Native only worked on the main isolate,
// the "run blocking calls in a helper isolate" approach would be impossible.
//
// (The reactor shards already call duneReactorCreate() from spawned isolates,
// so this is expected to work — but it's the load-bearing assumption, so prove
// it directly.) duneReactorCreate/Close need no tailscale node.
import 'dart:isolate';

import 'package:tailscale/src/ffi_bindings.dart' as native;

Future<void> main() async {
  // Baseline on the main isolate.
  final mainHandle = native.duneReactorCreate();
  print('main isolate: duneReactorCreate() = $mainHandle '
      '(${mainHandle >= 0 ? "ok" : "FAIL"})');
  if (mainHandle >= 0) native.duneReactorClose(mainHandle);

  // The real test: a fresh Isolate.run invoking the @Native asset binding.
  final viaRun = await Isolate.run(() {
    final h = native.duneReactorCreate();
    if (h >= 0) native.duneReactorClose(h);
    return h;
  });
  print('Isolate.run: duneReactorCreate() = $viaRun '
      '(${viaRun >= 0 ? "ok — @Native asset works in a helper isolate" : "FAIL"})');

  // And via Isolate.spawn (the kill-able variant we'd use for cancellation).
  final reply = ReceivePort();
  await Isolate.spawn((SendPort p) {
    final h = native.duneReactorCreate();
    if (h >= 0) native.duneReactorClose(h);
    p.send(h);
  }, reply.sendPort);
  final viaSpawn = await reply.first as int;
  reply.close();
  print('Isolate.spawn: duneReactorCreate() = $viaSpawn '
      '(${viaSpawn >= 0 ? "ok" : "FAIL"})');

  print('');
  print(viaRun >= 0 && viaSpawn >= 0
      ? 'VALIDATED: native-asset @Native bindings run in helper isolates.'
      : 'BLOCKED: native asset does not resolve in a helper isolate.');
}
