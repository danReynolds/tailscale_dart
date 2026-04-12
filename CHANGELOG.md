## 0.1.0

- Initial release.
- Embed a Tailscale node directly in any Dart or Flutter application.
- `Tailscale.init()` — configure once at startup with state directory and log level.
- `start()` — connect to a Tailscale or Headscale network. Reconnects from stored state on subsequent launches.
- `http` — a standard `http.Client` that routes requests through the WireGuard tunnel.
- `listen()` — accept incoming traffic from the tailnet, forwarded to a local port.
- `status()` — typed `TailscaleStatus` with peers, local IP, health, and backend state.
- `isProvisioned()` — check for stored credentials from a previous session.
- `close()` — disconnect, preserving state for reconnection.
- Automatic native Go compilation via Dart build hook — no manual build steps.
- Zero main-isolate jank: all FFI calls run on background isolates.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Full test suite: unit, FFI integration, and E2E against Headscale in CI.
