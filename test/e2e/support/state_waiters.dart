import 'dart:async';

import 'package:tailscale/tailscale.dart';

/// Records state changes until [terminal] is observed.
///
/// This timeout is a ceiling, not a wait: a transition that completes in 2s
/// costs 2s, so the value only bounds the failure case. It is sized for the one
/// genuinely variable leg — Headscale auth (first-boot or credential-reconnect)
/// against a containerized control plane on a contended CI runner — where the
/// original 30s occasionally fell short. 45s adds headroom over that without
/// being so generous it masks a real slowdown (a transition that suddenly takes
/// 40s should still fail the suite). Fast synthetic paths (Stopped, NoState)
/// complete in well under a second and are unaffected.
Future<List<NodeState>> recordUntil(
  Tailscale tsnet,
  NodeState terminal,
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 45),
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

/// Establishes and confirms the bidirectional data path to [peerIpv4] before
/// the timed two-node data-plane tests run.
///
/// Path establishment (endpoint discovery + DERP negotiation on a cold tailnet)
/// takes several seconds — more on a loaded CI runner — so racing it inside an
/// individual test's fixed timeout is the primary source of e2e flakiness.
/// Front-load it here with a retrying, generously-budgeted probe against the
/// peer's `/hello` endpoint: a successful outbound round-trip brings the tunnel
/// up in both directions, so subsequent inbound (peer→self) requests are fast
/// too. Each attempt is individually bounded so a single hung probe can't
/// consume the whole [budget]. Throws if the path never comes up.
Future<void> awaitDataPath(
  Tailscale tsnet,
  String peerIpv4, {
  Duration budget = const Duration(seconds: 90),
  Duration perAttempt = const Duration(seconds: 5),
  Duration interval = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(budget);
  Object? lastError = 'no attempt made';
  var attempts = 0;
  while (!DateTime.now().isAfter(deadline)) {
    attempts++;
    try {
      final resp = await tsnet.http.client
          .get(Uri.parse('http://$peerIpv4/hello'))
          .timeout(perAttempt);
      if (resp.statusCode == 200) return;
      lastError = 'HTTP ${resp.statusCode}';
    } on Object catch (e) {
      lastError = e;
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    'data path to $peerIpv4 not ready after $attempts attempts in $budget '
    '(last: $lastError)',
  );
}
