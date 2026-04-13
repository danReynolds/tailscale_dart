## 0.1.0

- Initial release.
- Embed a Tailscale node directly in any Dart or Flutter application.
- `Tailscale.init()` — configure once at startup with state directory, log level, and callbacks.
- `start()` — connect to a Tailscale or Headscale network. Returns when the node reaches Running state. Reconnects from stored state on subsequent launches.
- `http` — a standard `http.Client` that routes requests through the WireGuard tunnel.
- `listen()` — accept incoming traffic from the tailnet, forwarded to a local port.
- `status()` — typed `TailscaleStatus` with `NodeStatus` enum, peers, local IP, and health.
- `onStatusChange` / `onError` — real-time callbacks pushed from Go via NativePort (no polling).
- `isProvisioned()` — check for stored credentials from a previous session.
- `close()` — disconnect, preserving state for reconnection.
- `NodeStatus` enum: `noState`, `needsLogin`, `needsMachineAuth`, `starting`, `running`, `stopped`.
- Automatic native Go compilation via Dart build hook — no manual build steps.
- Zero main-isolate jank: all FFI calls run on background isolates.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Full test suite: unit, FFI integration, and E2E against Headscale in CI.
