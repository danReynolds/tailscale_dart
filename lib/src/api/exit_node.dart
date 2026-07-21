import 'dart:async';

import 'package:meta/meta.dart';

import '../status.dart';

typedef ExitNodeCurrentFn = Future<TailscaleNode?> Function();
typedef ExitNodeSuggestFn = Future<TailscaleNode?> Function();
typedef ExitNodeUseByIdFn = Future<void> Function(String stableNodeId);
typedef ExitNodeUseAutoFn = Future<void> Function();
typedef ExitNodeClearFn = Future<void> Function();

/// Exit-node routing: route this node's internet-bound traffic
/// through another tailnet node, VPN-style. The exit node becomes the
/// last hop before the public internet, so outbound connections
/// appear to originate from its IP.
///
/// Exit-node capability is opt-in on both sides: the serving node
/// must advertise it and be approved by an admin on the control
/// plane; any node on the tailnet can then opt into routing through
/// it. Applies only to traffic leaving the tailnet — node-to-node
/// tailnet traffic is unaffected.
///
/// See Tailscale's docs for the full feature (eligibility, approval,
/// split DNS behavior, LAN access):
/// <https://tailscale.com/kb/1103/exit-nodes>.
///
/// Reached via [Tailscale.exitNode].
abstract class ExitNode {
  /// The node currently being used as this node's exit, or null if none.
  Future<TailscaleNode?> current();

  /// The control plane's recommended exit node for this tailnet
  /// (latency-based). Returns null if no eligible node is available.
  Future<TailscaleNode?> suggest();

  /// Routes all outbound traffic through [node].
  ///
  /// Prefer this over [useById] — passing a [TailscaleNode] you got from
  /// `Tailscale.nodes()` catches stale identifiers at the type level.
  Future<void> use(TailscaleNode node) => useById(node.stableNodeId);

  /// Escape hatch for pinning an exit node by stable node ID — useful
  /// when the caller has persisted an ID across sessions and doesn't
  /// have the full [TailscaleNode] handy.
  ///
  /// [stableNodeId] is the value from [TailscaleNode.stableNodeId]
  /// (e.g. `nAbCd1234`), not a public key.
  Future<void> useById(String stableNodeId);

  /// Enables `AutoExitNode` mode — the control plane picks (and
  /// re-picks, on changes) the lowest-latency eligible exit node.
  Future<void> useAuto();

  /// Stops routing through an exit node.
  Future<void> clear();

  /// Emits whenever the exit-node selection changes (including external
  /// changes from another device signed into the same account).
  Stream<TailscaleNode?> get onCurrentChange;
}

/// Library-internal factory. Reach via `Tailscale.instance.exitNode`.
@internal
ExitNode createExitNode({
  required ExitNodeCurrentFn currentFn,
  required ExitNodeSuggestFn suggestFn,
  required ExitNodeUseByIdFn useByIdFn,
  required ExitNodeUseAutoFn useAutoFn,
  required ExitNodeClearFn clearFn,
  required Stream<List<TailscaleNode>> nodeChanges,
}) => _ExitNode(
  currentFn: currentFn,
  suggestFn: suggestFn,
  useByIdFn: useByIdFn,
  useAutoFn: useAutoFn,
  clearFn: clearFn,
  nodeChanges: nodeChanges,
);

final class _ExitNode extends ExitNode {
  _ExitNode({
    required ExitNodeCurrentFn currentFn,
    required ExitNodeSuggestFn suggestFn,
    required ExitNodeUseByIdFn useByIdFn,
    required ExitNodeUseAutoFn useAutoFn,
    required ExitNodeClearFn clearFn,
    required Stream<List<TailscaleNode>> nodeChanges,
  }) : _current = currentFn,
       _suggest = suggestFn,
       _useById = useByIdFn,
       _useAuto = useAutoFn,
       _clear = clearFn,
       _nodeChanges = nodeChanges;

  final ExitNodeCurrentFn _current;
  final ExitNodeSuggestFn _suggest;
  final ExitNodeUseByIdFn _useById;
  final ExitNodeUseAutoFn _useAuto;
  final ExitNodeClearFn _clear;
  final Stream<List<TailscaleNode>> _nodeChanges;
  final _localChanges = StreamController<void>.broadcast();

  @override
  Future<TailscaleNode?> current() => _current();

  @override
  Future<TailscaleNode?> suggest() => _suggest();

  @override
  Future<void> useById(String stableNodeId) async {
    // async so the empty-id guard rejects the returned Future rather than
    // throwing synchronously, consistent with the other exit-node methods.
    final id = stableNodeId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        stableNodeId,
        'stableNodeId',
        'must not be empty',
      );
    }
    return _runAndPublish(_useById(id));
  }

  @override
  Future<void> useAuto() => _runAndPublish(_useAuto());

  @override
  Future<void> clear() => _runAndPublish(_clear());

  Future<void> _runAndPublish(Future<void> operation) async {
    await operation;
    _localChanges.add(null);
  }

  @override
  Stream<TailscaleNode?> get onCurrentChange => Stream<TailscaleNode?>.multi((
    controller,
  ) {
    var canceled = false;
    var closed = false;
    TailscaleNode? last;
    var hasLast = false;

    // Adds must be guarded against a closed controller: `add`/`addError` throw
    // `StateError` after close, and since emissions are serialized on a chain
    // below, an escaped throw would permanently kill the chain (all later emits
    // stop). `closed` is set synchronously before `controller.close()`, so a
    // guarded emit can't race the close. `canceled` covers consumer teardown.
    void addSafe(TailscaleNode? node) {
      if (canceled || closed) return;
      controller.add(node);
    }

    void addErrorSafe(Object error, StackTrace stackTrace) {
      if (canceled || closed) return;
      controller.addError(error, stackTrace);
    }

    void closeController() {
      if (closed) return;
      closed = true;
      controller.close();
    }

    Future<void> emitIfChanged() async {
      try {
        final current = await _current();
        if (canceled || closed) return;
        final same = hasLast && current?.stableNodeId == last?.stableNodeId;
        if (same) return;
        hasLast = true;
        last = current;
        addSafe(current);
      } catch (error, stackTrace) {
        addErrorSafe(error, stackTrace);
      }
    }

    // Serialize emissions. Each trigger does an async `_current()` fetch and
    // then a read-modify-write of `last`/`hasLast`; running them concurrently
    // lets two see `hasLast == false` (duplicate first emit) or finish out of
    // order (a stale `current()` published after a newer one). A chain makes
    // each emit atomic and ordered; `addSafe`/`addErrorSafe` keep a
    // post-close throw from breaking the chain.
    var emitChain = Future<void>.value();
    void scheduleEmit() {
      emitChain = emitChain.then((_) => emitIfChanged());
    }

    scheduleEmit();
    final nodeSub = _nodeChanges.listen(
      (_) => scheduleEmit(),
      onError: addErrorSafe,
      onDone: closeController,
    );
    final localSub = _localChanges.stream.listen(
      (_) => scheduleEmit(),
      onError: addErrorSafe,
      onDone: closeController,
    );
    controller.onCancel = () {
      canceled = true;
      unawaited(nodeSub.cancel());
      unawaited(localSub.cancel());
    };
  }, isBroadcast: true);
}
