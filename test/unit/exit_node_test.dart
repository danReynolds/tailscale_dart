library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tailscale/src/api/exit_node.dart' show createExitNode;
import 'package:tailscale/tailscale.dart';

void main() {
  group('ExitNode wrapper', () {
    test('use delegates stable node ID', () async {
      String? usedId;
      final exitNode = createExitNode(
        currentFn: () async => null,
        suggestFn: () async => null,
        useByIdFn: (id) async {
          usedId = id;
        },
        useAutoFn: () async {},
        clearFn: () async {},
        nodeChanges: const Stream.empty(),
      );

      await exitNode.use(
        const TailscaleNode(
          publicKey: 'nodekey',
          stableNodeId: 'n123',
          hostName: 'router',
          dnsName: 'router.tailnet.ts.net.',
          os: 'linux',
          tailscaleIPs: ['100.64.0.1'],
          online: true,
          active: true,
          rxBytes: 0,
          txBytes: 0,
        ),
      );

      expect(usedId, 'n123');
    });

    test('onCurrentChange emits distinct current selections', () async {
      final nodes = StreamController<List<TailscaleNode>>.broadcast();
      var current = _node('n1');
      final exitNode = createExitNode(
        currentFn: () async => current,
        suggestFn: () async => null,
        useByIdFn: (_) async {},
        useAutoFn: () async {},
        clearFn: () async {},
        nodeChanges: nodes.stream,
      );

      final seen = <String?>[];
      final sub = exitNode.onCurrentChange.listen(
        (node) => seen.add(node?.stableNodeId),
      );

      await Future<void>.delayed(Duration.zero);
      nodes.add([current]);
      await Future<void>.delayed(Duration.zero);
      current = _node('n2');
      nodes.add([current]);
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['n1', 'n2']);
      await sub.cancel();
      await nodes.close();
    });

    test('onCurrentChange reacts to local mutations', () async {
      final nodes = StreamController<List<TailscaleNode>>.broadcast();
      var current = _node('n1');
      final exitNode = createExitNode(
        currentFn: () async => current,
        suggestFn: () async => null,
        useByIdFn: (id) async {
          current = _node(id);
        },
        useAutoFn: () async {},
        clearFn: () async {},
        nodeChanges: nodes.stream,
      );

      final seen = <String?>[];
      final sub = exitNode.onCurrentChange.listen(
        (node) => seen.add(node?.stableNodeId),
      );
      await Future<void>.delayed(Duration.zero);

      await exitNode.useById('n2');
      for (var i = 0; i < 5 && seen.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(seen, ['n1', 'n2']);
      await sub.cancel();
      await nodes.close();
    });

    test('an emit resuming after the source closed does not crash', () async {
      // Smoke test for the source-close shutdown path: an emit that resumes
      // after the stream's controller closed must not surface an unhandled
      // error. (The specific add-after-close crash the `closed` guard prevents
      // is latent today — the source controllers are never actually closed — so
      // this exercises the path rather than strictly failing without the fix.)
      // A completer-gated currentFn makes the ordering exact: the emit blocks
      // until we close the source, then resumes post-close.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final nodes = StreamController<List<TailscaleNode>>.broadcast();
        final gate = Completer<TailscaleNode?>();
        final exitNode = createExitNode(
          currentFn: () => gate.future,
          suggestFn: () async => null,
          useByIdFn: (_) async {},
          useAutoFn: () async {},
          clearFn: () async {},
          nodeChanges: nodes.stream,
        );

        final sub = exitNode.onCurrentChange.listen((_) {});
        // Let the initial emit start and park on `gate.future`.
        await Future<void>.delayed(Duration.zero);
        // Close the source → the stream's controller closes.
        await nodes.close();
        // Now let the parked emit resume; it must observe `closed` and not
        // call add on the closed controller.
        gate.complete(_node('n1'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();
      }, (error, _) => errors.add(error));
      expect(
        errors,
        isEmpty,
        reason: 'a post-close emit must not crash the emission chain',
      );
    });
  });
}

TailscaleNode _node(String id) => TailscaleNode(
  publicKey: 'nodekey-$id',
  stableNodeId: id,
  hostName: 'node-$id',
  dnsName: 'node-$id.tailnet.ts.net.',
  os: 'linux',
  tailscaleIPs: const ['100.64.0.1'],
  online: true,
  active: true,
  rxBytes: 0,
  txBytes: 0,
);
