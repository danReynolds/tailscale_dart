# dune_smoke_flutter

Automated Flutter smoke probe for `package:tailscale`.

This app is intentionally separate from `packages/demo_flutter`, which is the
manual human-facing demo. The smoke app starts automatically from
`--dart-define` configuration, joins a Headscale-backed tailnet, starts the
demo HTTP/TCP/UDP services, probes a known headless peer, and prints one
machine-readable result line:

```text
DUNE_SMOKE_RESULT {"ok":true,...}
```

The matrix runner in `tool/smoke/run_matrix.dart` parses that line from
`flutter run` logs.

## Role

Use this package only for automated platform validation. It is deliberately
minimal and machine-driven:

- no admin auth-key UI
- no manual node browser
- no long-lived debugging workflow
- no assertions beyond "this Flutter runtime can join and move traffic"

For manual validation, use `packages/demo_flutter`. For reusable validation
logic, use `packages/demo_core`.

## Runner Workflow

The normal entrypoint is from the repo root:

```sh
tool/smoke/run_matrix.sh
```

The runner:

1. starts Docker Headscale
2. creates a reusable Headscale auth key
3. starts one headless `demo_core` peer
4. runs this Flutter app on each selected platform target
5. receives the result over `POST /result`
6. tears down Headscale and any emulator it launched, unless told to keep them

Useful variants:

```sh
tool/smoke/run_matrix.sh --targets macos,ios,android --jobs 3
tool/smoke/run_matrix.sh --targets android --android-avd Resizable_API_33
tool/smoke/run_matrix.sh --targets android --android-avd Resizable_API_33 \
  --reuse-headscale --keep-android-emulator
```

Android runs in Flutter profile mode by default because the debug APK is much
larger and slower to install. Use `--android-run-mode debug` only when debugging
Flutter startup behavior.

## Result Semantics

The app starts its own HTTP/TCP/UDP demo services, then probes the headless peer.
The required smoke probes are:

- WhoIs
- HTTP GET
- HTTP POST
- TCP echo
- UDP echo

Ping is included as diagnostic output but is not required for a pass. LocalAPI
ping can lag during fresh netmap and DERP convergence even when the package data
paths are working.

Dart defines (all compile-time):

- `DUNE_SMOKE_RUNNER_URL` — the matrix runner's local HTTP server. Default
  `http://localhost:18099`. Per-target override needed when the device cannot
  reach `localhost` on the host (Android emulator: `http://10.0.2.2:18099`,
  wireless iOS device: host LAN IP).
- `DUNE_SMOKE_SESSION` — short identifier for this run, surfaced as the chip
  label and used to scope `/config` and `/result` requests. The matrix runner
  passes the target name (`macos`, `ios`, `android`).
- `DUNE_SMOKE_RUNNER_TOKEN` — stable per-worktree token used to authorize
  `/config` and `/result`. The runner creates one under `.dart_tool` when not
  provided through the environment.

The auth key, control URL, target IP, hostname, and state suffix are returned
by the runner over HTTP at `GET /config?session=<session>`. The smoke app
posts its result to `POST /result?session=<session>` with the runner token in
the `x-dune-smoke-token` header. It also emits the same JSON to stdout as a
fallback diagnostic for the matrix runner.
