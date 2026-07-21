import 'dart:async';

import 'package:tailscale/src/api/exit_node.dart';
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  // Regression guard for the sync-throw bug: a pre-condition guard on these
  // methods must reject the returned Future rather than throw synchronously,
  // so callers using `.catchError` / `await` handle them uniformly with every
  // other async method. Capturing the Future before asserting proves the call
  // itself did not throw synchronously.

  test('nodes()/whois() reject via Future when uninitialized', () async {
    final tailscale = Tailscale.instance;

    final nodesFuture = tailscale.nodes();
    await expectLater(nodesFuture, throwsA(isA<TailscaleUsageException>()));

    final whoisFuture = tailscale.whois('100.64.0.1');
    await expectLater(whoisFuture, throwsA(isA<TailscaleUsageException>()));
  });

  test('exitNode.useById() rejects a blank id via Future', () async {
    final exitNode = createExitNode(
      currentFn: () async => null,
      suggestFn: () async => null,
      useByIdFn: (_) async {},
      useAutoFn: () async {},
      clearFn: () async {},
      nodeChanges: const Stream<List<TailscaleNode>>.empty(),
    );

    final future = exitNode.useById('   ');
    await expectLater(future, throwsA(isA<ArgumentError>()));
  });
}
