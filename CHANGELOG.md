## 0.2.0

- tsnet.Server.Close() doesn't fire a terminal state through the IPN bus, so onStateChange subscribers drifted from the engine — stuck at the pre-stop value (usually Running) and their UI routing went stale.
- Stop() now publishes Stopped, gated on srv != nil so a no-op stop stays silent. Logout() follows up with NoState after wiping creds (full sequence on logout from a running node: Stopped → NoState).
- Rewrites the onStateChange lifecycle e2e group around a new _recordUntil helper that captures full emitted sequences, and adds coverage for the no-op-down guard, broadcast delivery to multiple subscribers, and the ordered Stopped → NoState emit on logout.

## 0.1.0

- Initial release.
- Embed a Tailscale node directly in any Dart or Flutter application.
- `Tailscale.init()` — configure once at startup with state directory and log level.
- `up()` — start the embedded node and connect to a Tailscale or Headscale network.
- `http` — a standard `http.Client` that routes requests through the WireGuard tunnel.
- `listen()` — accept incoming traffic from the tailnet, forwarded to a local port.
- `status()` — typed `TailscaleStatus` with `NodeState` enum, local IPs, and health.
- `peers()` — typed `PeerStatus` snapshots, separate from status for lightweight polling.
- `onStateChange` / `onError` — real-time streams pushed from Go via NativePort (no polling).
- `down()` — disconnect, preserving state for reconnection.
- `logout()` — disconnect and clear persisted state.
- `NodeState` enum: `noState`, `needsLogin`, `needsMachineAuth`, `starting`, `running`, `stopped`.
- Automatic native Go compilation via Dart build hook — no manual build steps.
- Zero main-isolate jank: all FFI calls run on a background isolate.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Full test suite: unit, FFI integration, and E2E against Headscale in Docker.
 