# dune_core_flutter

Flutter validation app for manually exercising `package:tailscale` on macOS,
iOS, and Android.

The app depends on `demo_core` for all Tailscale behavior. Its job is only to
provide a small UI for:

- joining as a client with an auth key and optional control URL
- joining as an admin with only a Tailscale API key and tailnet ID
- issuing short-lived client auth keys from Admin mode
- exposing demo HTTP, TCP, and UDP services
- listing nodes
- probing another node end to end

## Connecting to local Headscale

Use **Client** mode for the local Headscale E2E stack. **Admin** mode is only
for Tailscale's hosted admin API because it calls `api.tailscale.com` to create
auth keys.

1. Start the local Headscale stack from the repo root:

   ```sh
   docker compose -f test/e2e/docker-compose.yml up -d
   ```

2. Create a reusable preauth key:

   ```sh
   docker compose -f test/e2e/docker-compose.yml exec -T headscale \
     headscale preauthkeys create --user dune-demo --reusable --expiration 24h
   ```

3. Fill the app in **Client** mode:

   - `Hostname`: any unique name, for example `demo-macos` or `demo-ios`.
   - `Auth key`: the preauth key from step 2.
   - `Control URL` on macOS: `http://localhost:8080`.
   - `Control URL` on a physical iOS/Android device: use the Mac's LAN IP,
     for example `http://192.168.86.22:8080`.

   To find the Mac LAN IP:

   ```sh
   ipconfig getifaddr en0
   ```

4. Tap **Join as client** and wait for `RUNNING`.

5. Verify `Runtime Telemetry` shows `SERVICES DemoServices(ip: ...)` using the
   same IP as the node `IPv4` value. If services are not running, tap
   **Start services**.

6. Probe an online node from the Node Matrix. A healthy demo path passes ping,
   whois, HTTP GET/POST, TCP echo, and UDP echo.

For faster local iteration without deploying Flutter to a device, use
`packages/demo_core/bin/demo_node.dart` as a headless node. Run `serve` in a
terminal and keep it open; by default it stays alive until `SIGINT`/`SIGTERM`.
Automation that needs `PROBE <ip>` and `STOP` over stdin should pass
`--stdin-control`.
