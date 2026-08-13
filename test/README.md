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
- **Live Tailscale tests** live in `test/live_tailscale/`. They are
  on-demand tests against Tailscale's hosted control plane for behavior
  Headscale cannot model, such as HTTPS certificate issuance, Funnel policy,
  exit-node recommendations, and route approval.

## What Runs Where

| Suite | Command | Runs by default? | External dependency | Purpose |
| --- | --- | --- | --- | --- |
| Static analysis | `dart analyze` | Yes, PR gate | None | Analyzer/type/lint correctness. |
| Root Dart suite | `dart test --exclude-tags live-tailscale` | Yes, PR gate | None | Unit, FFI, fd, runtime tests. Persistent runtime integration uses a package-internal in-memory Keybay test backend, not the Linux Secret Service. E2E registers as a no-op without Headscale variables; hosted-live tests are explicitly excluded even if credentials happen to be exported. |
| Go suite | `cd go && go test -count=1 ./...` | Yes, PR gate | None | Go wrappers, LocalAPI mapping helpers, native-side validation. |
| Headscale E2E + R8 receipts | `test/e2e/run_e2e.sh` | Yes, PR gate | Docker | Starts local Headscale; exercises encrypted persistent enrollment/reconnect, HTTP/TCP/UDP, the classified R6 persistent-file inventory, and separate-process R8 latency/load/churn receipts. The test custodian is not production Linux Secret Service. |
| Local full suite | `tool/test_local_full.sh` | No, local/release confidence | Docker for Headscale | PR gate plus demo package tests and whitespace checks. |
| Platform smoke matrix | `tool/smoke/run_matrix.sh` | No, local/release confidence | Docker plus local Flutter platforms/devices | Runs explicitly ephemeral nodes to validate native asset packaging and HTTP/TCP/UDP smoke behavior on macOS/iOS/Android/etc.; it is not a persistent-storage receipt. |
| Live Tailscale routing controls | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_routing_controls_test.dart` | No, opt-in only | Tailscale SaaS + API key | Validates hosted-control-plane behavior Headscale cannot model: exit-node route approval, `suggest`, `useAuto`, and cleanup. |
| Live Tailscale TLS | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_tls_listener_test.dart` | No, opt-in only | Tailscale SaaS + HTTPS-enabled tailnet | Validates successful `tls.bind` serving. Headscale can only validate the clear failure path because it does not provision Tailscale HTTPS certificates. |
| Live Tailscale Serve | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_serve_forward_test.dart` | No, opt-in only | Tailscale SaaS + HTTPS-enabled tailnet | Validates `serve.forward` end-to-end by proxying a loopback HTTP server and fetching it from a second embedded node. |
| Live Tailscale Funnel | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_funnel_forward_test.dart` | No, opt-in only | Tailscale SaaS + HTTPS/Funnel-enabled tailnet + `curl` | Validates `funnel.forward` end-to-end by proxying a loopback HTTP server and fetching its public Funnel URL. Uses DNS-over-HTTPS plus `curl --resolve` to avoid local negative DNS caching while preserving SNI/Host. |
| Live Funnel tailnet reach | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_funnel_tailnet_reach_test.dart` | No, opt-in only | Tailscale SaaS + HTTPS/Funnel-enabled tailnet | R5 receipt that a Funnel ServeConfig publication remains reachable from a second node inside the tailnet. |
| Live Serve/Funnel swap | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_funnel_serve_swap_test.dart` | No, opt-in only | Tailscale SaaS + HTTPS/Funnel-enabled tailnet + `curl` | Regression receipt for issue #87: Serve -> Funnel -> Serve on one coordinate, including public Funnel ingress and stale exact-handle closes. |
| Live publication crash/restart | `TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... dart test test/live_tailscale/live_publication_crash_restart_test.dart` | No, opt-in only; macOS | Tailscale SaaS + production macOS Keybay | R6 receipt: persist a Serve mapping, SIGKILL its process, bind a sentinel to the old local port, reopen the same encrypted identity without auth, and continuously prove stale ServeConfig never reaches the sentinel before or after package Running. |

The default development loop is therefore:

```bash
dart analyze
dart test --exclude-tags live-tailscale
cd go && go test -count=1 ./...
```

The required PR-equivalent loop is:

```bash
tool/test_pr_gate.sh
```

The live Tailscale suite is deliberately outside default CI. It is repeatable,
but it depends on hosted Tailscale state and a secret with permissions to create
and revoke auth keys, list/delete devices, and approve routes.

## Secure-State Evidence Boundary

The ordinary Linux PR/runtime integration path installs a package-internal
in-memory Keybay backend through the test-only storage-factory seam. That keeps
the encrypted Store, Dart custody coordinator, binary FFI, lifecycle, reset,
and failure behavior deterministic, but it does **not** exercise Linux
`secret-tool`, Secret Service locking/unlocking, or a real platform keystore.

Headscale E2E uses a conspicuously test-only file custodian for the primary
node and cross-process persistence cases. That proves encrypted-StateStore
enrollment, reconnect, logout/reset, and tailnet behavior in headless CI, but
the custodian is not production Keybay and is not a platform security receipt.
Disposable peer cases remain explicitly ephemeral. The smoke runner likewise
passes `--ephemeral` to its headless `demo_core` peer, and the Flutter smoke app
calls `up(ephemeral: true)`; those nodes use in-memory StateStores and never
access Keybay.

The macOS CLI production-Keybay receipt now proves fresh persistent enrollment,
same-node recovery without an auth key after SIGKILL, automatic stale-
publication cleanup, and explicit DEK/state-subtree reset. Equivalent real-
Keybay evidence on each other claimed persistent platform, platform backup
exclusion, fail-closed platform permissions, custody fault injection, and the
mobile persistent-sidecar inventory remain R6 evidence. The first-party demo's
Apple exclusion/readback code and Android backup rules compile in CI/local
builds, but physical readback is still required. A green Linux PR gate,
Headscale E2E run, or smoke matrix is not a substitute for those device
receipts.

The Headscale E2E run does provide the non-device inventory authority for its
own path: after normal HTTP/TCP/UDP use it classifies every relative artifact,
checks owner-only modes, and prints `R6_STATE_INVENTORY` without file contents.
The same classifier is used by hosted TLS and Serve/Funnel receipt tests.

## Placement Rules

- If a socketpair or fake fd can reproduce the behavior faithfully, put the test
  in `test/integration/fd/`.
- If the behavior depends on Headscale, netmap state, WireGuard routing,
  magicsock/DERP, peer identity, or another node, put it in `test/e2e/`.
- If the behavior specifically depends on Tailscale SaaS policy or
  recommendation behavior that Headscale does not implement, put it in
  `test/live_tailscale/` and gate it behind environment variables.
- If the behavior is a pure data model, parser, or error-shape contract, put it
  in `test/unit/`.
- If the behavior is Go-only below FFI, prefer a Go test in `go/` first.

## Commands

```bash
dart analyze
dart test --exclude-tags live-tailscale
cd go && go test -count=1 ./...
test/e2e/run_e2e.sh
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_routing_controls_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_tls_listener_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_serve_forward_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_funnel_forward_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_funnel_tailnet_reach_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_funnel_serve_swap_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_publication_crash_restart_test.dart
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
- Dart analysis and root tests, using the internal in-memory Keybay test backend
  for persistent runtime integration.
- Headscale E2E with the test-only persistent custodian plus ephemeral peers.
- R8 identity latency, sustained CPU/throughput, exact TCP/HTTP accepts, and
  netmap-replacement load in separate Go processes.

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

The smoke matrix starts Docker Headscale, starts one explicitly ephemeral
headless `demo_core` peer, then runs `packages/demo_smoke_flutter` as a second
explicitly ephemeral node on each available Flutter platform target. The app
joins the Headscale tailnet, starts the demo HTTP/TCP/UDP services, probes the
headless peer, and prints a
`DUNE_SMOKE_RESULT` JSON line for the runner to parse.

Before starting the tailnet, the runner refreshes dependencies for
`packages/demo_core` and `packages/demo_smoke_flutter` so a clean worktree does
not fail later with a missing `.dart_tool/package_config.json`.

Smoke is a platform packaging/runtime check, not the canonical correctness
suite. The detailed protocol and API assertions live in unit, integration, and
Headscale E2E tests. The smoke matrix answers a narrower question: "Can this
Flutter runtime load the native asset, start tsnet, join the control plane, and
move HTTP/TCP/UDP traffic to another node?" Because both nodes are ephemeral,
its same-process restart/re-enrollment cycle does not qualify persistent Keybay
reconnect across process death.

Targets can be selected or made strict:

```bash
tool/smoke/run_matrix.sh --targets macos,ios
tool/smoke/run_matrix.sh --targets macos,ios,android --strict
tool/smoke/run_matrix.sh --targets macos,ios,android --jobs 3
```

By default, unavailable targets are skipped so a local machine can run the
subset it actually has: macOS desktop on macOS and any connected or booted
iOS/Android devices known to `flutter devices`. Flutter Linux desktop smoke is
available as an explicit `--targets linux` check, but is not part of the normal
matrix.

Docker Headscale E2E and Linux validation are related but not identical.
Headscale itself always runs in Docker; the embedded Dart nodes run on the host
that invokes `dart test`. On Linux CI or a Linux VM, `test/e2e/run_e2e.sh`
validates the Linux native-asset and epoll reactor path. On macOS, the same
script still validates real Headscale tailnet behavior, but the fd backend under
test is the macOS kqueue backend because the Dart nodes are macOS processes.

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

### Live Tailscale Routing Controls

The Headscale E2E suite proves that prefs and exit-node setters reach LocalAPI.
It cannot prove Tailscale SaaS-specific exit-node recommendation policy. The
live routing-controls suite fills that gap.

```bash
TAILSCALE_API_KEY=... \
TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_routing_controls_test.dart
```

The suite creates short-lived ephemeral auth keys, starts two embedded nodes, makes one
node advertise default routes, approves those routes with the Tailscale device
routes API, and verifies `exitNode.suggest()`, `use(node)`, `useAuto()`, and
`clear()`. The API key must be able to create auth keys, list devices, enable
device routes, and delete test devices. Do not run this in PR CI; it depends on
hosted control-plane state and a secret. Rotate the API key after sharing it.

Physical devices usually need a reachable host LAN URL. The runner exposes
both the Headscale control plane and a small config-fetch HTTP server back to
the smoke app, so override both and explicitly bind the runner server to a
reachable interface:

```bash
DUNE_SMOKE_CONTROL_URL_IOS=http://192.168.86.22:18080 \
DUNE_SMOKE_RUNNER_URL_IOS=http://192.168.86.22:18099 \
  tool/smoke/run_matrix.sh --targets ios --ios-device <device-id> \
  --runner-bind-address 0.0.0.0
```

The runner HTTP server binds to `127.0.0.1` by default and protects `/config`
and `/result` with a stable per-worktree token passed to the smoke app as a
dart-define. Binding to `0.0.0.0` should be limited to physical-device smoke
runs on trusted networks because `/config` carries a short-lived Headscale auth
key.

Every run ends with a compact capability matrix derived from the same
machine-readable results that determine the smoke verdict. To collect
historical performance samples without replacing or weakening those assertions,
add profile mode and an explicit output path:

```bash
DUNE_SMOKE_CONTROL_URL_IOS=http://<host-lan-ip>:18080 \
DUNE_SMOKE_RUNNER_URL_IOS=http://<host-lan-ip>:18099 \
  tool/smoke/run_matrix.sh --targets ios --ios-device <device-id> \
  --runner-bind-address 0.0.0.0 --strict --timeout-seconds 900 \
  --profile-samples 20 \
  --output benchmark/results/<version>/devices/<date>-ios-arm64.json
```

Profiling requires one target and an explicit iOS/Android device, runs the app
in Flutter profile mode with Flutter tooling detached, and adds repeated
small-operation latency plus three five-second uploads and downloads over
Tailscale. One one-second upload and download over an ordinary host LAN socket
provide a lightweight ceiling check. The LAN control makes a later physical run
distinguish a tailnet/bridge bottleneck from device, Wi-Fi, or runtime behavior.
Correctness and profile collection have separate statuses. It writes
privacy-safe raw JSON and a generated Markdown summary. The detached launch
avoids profiler/debugger measurement effects and is recorded in the artifact.
For an explicitly non-comparable iOS Simulator diagnostic, add
`--profile-run-mode debug`.
Without `--output`, a profile is kept under the system temporary directory so
an exploratory run cannot silently become canonical history.

Real iOS/Android devices remain the release-confidence path because simulators
and emulators do not fully cover ARM64 packaging, mobile networking, app
lifecycle, or device-specific sandbox behavior. Dated production-custody and
hosted-control-plane results live in [`device_receipts/`](device_receipts/).
