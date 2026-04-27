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
5. parses the first `DUNE_SMOKE_RESULT` line from `flutter run`
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

Required dart defines:

- `DUNE_SMOKE_CONTROL_URL`
- `DUNE_SMOKE_AUTH_KEY`
- `DUNE_SMOKE_TARGET_IP`

Optional dart defines:

- `DUNE_SMOKE_HOSTNAME`
- `DUNE_SMOKE_STATE_SUFFIX`
