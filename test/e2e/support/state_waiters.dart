import 'dart:async';

import 'package:tailscale/tailscale.dart';

/// Records state changes until [terminal] is observed.
///
/// Headscale first-boot auth can be the slow leg on CI runners. Terminal-state
/// paths like Stopped and NoState are synthetic and nearly instant, so the
/// extra timeout headroom costs nothing when those paths succeed.
Future<List<NodeState>> recordUntil(
  Tailscale tsnet,
  NodeState terminal,
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final sequence = <NodeState>[];
  final done = Completer<void>();

  final sub = tsnet.onStateChange.listen((s) {
    sequence.add(s);
    if (s == terminal && !done.isCompleted) done.complete();
  });

  try {
    await action();
    await done.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'onStateChange never emitted $terminal; '
        'got [${sequence.join(' -> ')}]',
      ),
    );
    return sequence;
  } finally {
    await sub.cancel();
  }
}
