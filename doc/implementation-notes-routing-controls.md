# Routing Controls Implementation Note

This note tracks the Phase 6 routing-control work: preferences, subnet-route
controls, and exit-node controls. The implementation should stay thin over
Tailscale's LocalAPI; no new data-plane protocol is required.

## Scope

- `prefs.get()` maps the stable subset of `ipn.Prefs` into `TailscalePrefs`.
- `prefs.updateMasked(PrefsUpdate)` maps to `ipn.MaskedPrefs` and returns the
  updated prefs snapshot.
- Single-field prefs setters are Dart conveniences over `updateMasked`.
- `exitNode.current()` resolves the selected exit node from `PeerStatus.ExitNode`
  and falls back to the requested `Prefs.ExitNodeID` while path selection settles.
- `exitNode.suggest()` calls LocalAPI `suggest-exit-node` and maps the stable
  node ID back to the current `TailscaleNode` inventory.
- `exitNode.useById()` and `exitNode.clear()` are prefs updates.
- `exitNode.useAuto()` sets upstream `AutoExitNode=any`.
- `exitNode.onCurrentChange` is derived from node-inventory updates. It observes
  runtime selection changes, but external prefs-only changes may not emit until
  the next netmap/node update.

## Testability

Headscale validates prefs transport, Shields Up, route advertisement shape,
route acceptance toggles, and pinned exit-node prefs updates. The live
Tailscale suite in `test/live_tailscale/` validates the remaining
control-plane-specific exit-node behavior: route approval, `suggest()`,
pinned `use()`, `useAuto()`, and `clear()`.

## Checklist

- [x] Go LocalAPI wrappers for prefs get/update and exit-node suggest/auto.
- [x] Worker FFI plumbing and typed Dart parsing.
- [x] Public prefs and exit-node namespaces wired to `Tailscale.instance`.
- [x] Value/model tests for prefs and node exit-node fields.
- [x] FFI pre-start error-shape coverage.
- [x] Headscale E2E coverage for prefs updates that do not require route
      approval.
- [x] Live Tailscale validation for `exitNode.suggest()` / `useAuto()`.
