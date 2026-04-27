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
cd packages/demo_core && dart test
cd packages/demo_flutter && flutter test
```

Run Dart test commands serially. Several integration tests load the native
runtime, which has process-global state, and the native-assets hook can race if
multiple test commands rebuild the shared library at once.
