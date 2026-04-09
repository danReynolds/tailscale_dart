## 0.1.0

- Initial release.
- Embed a Tailscale node directly in any Dart or Flutter application.
- Outgoing HTTP proxy to reach peers on the tailnet.
- Reverse proxy to accept incoming traffic from the tailnet.
- Peer discovery and local IP resolution.
- Typed status model (`TailscaleStatus`, `PeerStatus`) and reactive `statusStream`.
- Persistent authentication via SQLite state store.
- Log level control (`setLogLevel`).
- Init timeout to handle unreachable control servers.
- Automatic native Go compilation via Dart build hook.
- Supports iOS, Android, macOS, Linux, and Windows.
- Works with Tailscale and self-hosted Headscale control servers.
- Zero main-isolate jank: all FFI calls run on background isolates.
