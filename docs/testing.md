# Testing

The test suite is organized by boundary. A test should live at the smallest
layer that proves the behavior.

## Layers

- **Unit tests** live in `test/unit/`. They cover pure Dart contracts: value
  semantics, JSON parsing, error types, state models, and API preconditions.
- **FFI integration tests** live in `test/integration/ffi/`. They verify that
  the compiled Go native asset loads and exported FFI functions return the
  documented shape before/around runtime startup.
- **FD integration tests** live in `test/integration/fd/`. They use local
  POSIX socketpairs to validate fd ownership, byte-stream semantics, datagram
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
```

Run Dart test commands serially. Several integration tests load the native
runtime, which has process-global state, and the native-assets hook can race if
multiple test commands rebuild the shared library at once.

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

This runs the PR gate, demo core tests, Flutter demo widget tests, and
`git diff --check`.

### Platform Compatibility Suite

Run this when changing native assets, fd transport, mobile startup, packaging,
or platform-specific networking:

- macOS: run the Flutter demo on macOS and execute the probe.
- iOS: run the Flutter demo on simulator or device and execute the probe.
- Android: run the Flutter demo on emulator or device and execute the probe.
- Linux: run `tool/test_pr_gate.sh`, which includes Docker Headscale E2E.

Real iOS/Android devices remain the release-confidence path because simulators
and emulators do not fully cover ARM64 packaging, mobile networking, app
lifecycle, or device-specific sandbox behavior.
