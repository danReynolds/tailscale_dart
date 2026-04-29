# Testing

The test suite is organized by boundary. A test should live at the smallest
layer that proves the behavior.

## Layers

- **Unit tests** live in `test/unit/`. They cover pure Dart contracts: value
  semantics, JSON parsing, error types, state models, and API preconditions.
- **FFI integration tests** live in `test/integration/ffi/`. They verify that
  the compiled Go native asset loads and exported FFI functions return the
  documented shape before/around runtime startup.
- **FD integration tests** live in `test/integration/fd/`. They use local POSIX
  socketpairs to validate fd ownership, byte-stream semantics, datagram
  envelopes, HTTP fd envelopes, cleanup, and backpressure without a tailnet.
- **Runtime integration tests** live in `test/integration/runtime/`. They use
  the embedded Go runtime through the public Dart API, but avoid real peer
  discovery and routing.
- **E2E tests** live in `test/e2e/`. They start Headscale in Docker, join real
  embedded nodes, and verify assembled tailnet behavior.

## Placement Rules

- If a socketpair or fake fd can reproduce the behavior faithfully, put the test
  in `test/integration/fd/`.
- If the behavior depends on Headscale, netmap state, WireGuard routing,
  magicsock/DERP, peer identity, or another node, put it in `test/e2e/`.
- If the behavior is a pure data model, parser, or error-shape contract, put it
  in `test/unit/`.
- If the behavior is Go-only below FFI, prefer a Go test in `go/` first.

## Commands

```bash
dart analyze
dart test
cd go && go test -count=1 ./...
test/e2e/run_e2e.sh
tool/test_pr_gate.sh
tool/test_local_full.sh
cd packages/demo_core && dart test
cd packages/demo_flutter && flutter test
cd packages/demo_smoke_flutter && flutter test
```

Run Dart test commands serially. Several integration tests load the native
runtime, which has process-global state, and the native-assets hook can race if
multiple test commands rebuild the shared library at once.

## Demo And Smoke Packages

The demo packages have separate jobs:

- `packages/demo_core`: reusable, UI-free validation logic. It owns node startup,
  service startup, auth-key helper calls, node listing, and probe execution. Use
  its `bin/demo_node.dart` CLI for fast headless local loops.
- `packages/demo_flutter`: manual human-facing demo app. Use it when a person is
  installing on macOS/iOS/Android, joining a tailnet, issuing auth keys, or
  visually probing nodes.
- `packages/demo_smoke_flutter`: automated Flutter smoke app. Do not use it as a
  product demo; it is a small app launched by `tool/smoke/run_matrix.sh` with
  `--dart-define` inputs and one machine-readable result line.

In short: `demo_core` is the shared engine, `demo_flutter` is the manual UI, and
`demo_smoke_flutter` is the automation target.

## Validation Tiers

### Required PR Gate

PR CI is intentionally narrow and fast. It runs on Linux and covers:

- Go tests.
- Dart analysis and root tests.
- Headscale E2E.

Run the same shape locally with:

```bash
tool/test_pr_gate.sh
```

### Local Full Suite

Run this before merging large transport changes or cutting releases:

```bash
tool/test_local_full.sh
```

This runs the PR gate, demo core tests, Flutter demo widget tests, Flutter smoke
widget tests, and `git diff --check`.

### Platform Compatibility Smoke Matrix

Run this when changing native assets, fd transport, mobile startup, packaging,
or platform-specific networking:

```bash
tool/smoke/run_matrix.sh
```

The smoke matrix starts Docker Headscale, starts one headless `demo_core` peer,
then runs `packages/demo_smoke_flutter` as a second node on each available
Flutter platform target. The app joins the Headscale tailnet, starts the demo
HTTP/TCP/UDP services, probes the headless peer, and prints a
`DUNE_SMOKE_RESULT` JSON line for the runner to parse.

Smoke is a platform packaging/runtime check, not the canonical correctness
suite. The detailed protocol and API assertions live in unit, integration, and
Headscale E2E tests. The smoke matrix answers a narrower question: "Can this
Flutter runtime load the native asset, start tsnet, join the control plane, and
move HTTP/TCP/UDP traffic to another node?"

Targets can be selected or made strict:

```bash
tool/smoke/run_matrix.sh --targets macos,ios
tool/smoke/run_matrix.sh --targets macos,ios,android --strict
tool/smoke/run_matrix.sh --targets macos,ios,android --jobs 3
```

By default, unavailable targets are skipped so a local machine can run the
subset it actually has: macOS desktop on macOS and any connected or booted
iOS/Android devices known to `flutter devices`. Linux package behavior is
covered by the Headscale E2E suite; Flutter Linux desktop smoke is available as
an explicit `--targets linux` check, but is not part of the normal matrix.

For Android emulator, the runner defaults the app control URL to
`http://10.0.2.2:$HEADSCALE_PORT` and waits for Android's package manager
before installing the app. Android runs in Flutter profile mode by default to
keep the APK smaller and reduce install time; pass `--android-run-mode debug`
when debugging app startup. If the emulator is not already running, the runner
can launch a named AVD:

```bash
tool/smoke/run_matrix.sh --targets android --android-avd Resizable_API_33
```

For faster repeat runs, keep Headscale and the emulator alive:

```bash
tool/smoke/run_matrix.sh --targets android \
  --android-avd Resizable_API_33 \
  --reuse-headscale \
  --keep-android-emulator
```

Cold Android emulator runs are still slow because they include emulator boot,
native asset build, Gradle build, and APK install. The fast local loop is to keep
the emulator warm and rerun the same target; use cold runs as compatibility
checks rather than inner-loop debugging.

`--jobs` runs platform targets concurrently after Headscale and the headless
peer are ready. Keep it at the default `1` when debugging noisy platform issues;
use `--jobs 3` for a faster local matrix once the individual targets are stable.

Physical devices usually need a reachable host LAN URL. The runner exposes
both the Headscale control plane and a small config-fetch HTTP server back to
the smoke app, so override both and explicitly bind the runner server to a
reachable interface:

```bash
DUNE_SMOKE_CONTROL_URL_IOS=http://192.168.86.22:18080 \
DUNE_SMOKE_RUNNER_URL_IOS=http://192.168.86.22:18099 \
  tool/smoke/run_matrix.sh --targets ios --runner-bind-address 0.0.0.0
```

The runner HTTP server binds to `127.0.0.1` by default and protects `/config`
and `/result` with a stable per-worktree token passed to the smoke app as a
dart-define. Binding to `0.0.0.0` should be limited to physical-device smoke
runs on trusted networks because `/config` carries a short-lived Headscale auth
key.

Real iOS/Android devices remain the release-confidence path because simulators
and emulators do not fully cover ARM64 packaging, mobile networking, app
lifecycle, or device-specific sandbox behavior.
