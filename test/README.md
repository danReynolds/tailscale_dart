# Test Layout

Tests are grouped by the smallest layer that can prove the contract.

- `unit/`: Pure Dart model, parsing, error, and API-shape tests. These should
  not load the native library or require a tailnet.
- `integration/ffi/`: Low-level Dart FFI binding tests against the compiled Go
  native asset.
- `integration/fd/`: Local POSIX fd/socketpair tests for byte streams, datagram
  envelopes, and HTTP fd lifecycle. These do not require Headscale.
- `integration/runtime/`: Public runtime API tests that use the embedded Go
  runtime but do not require a second node or real tailnet routing.
- `e2e/`: Headscale-backed system tests that join one or more embedded nodes to
  a real control plane and verify tailnet behavior.

Prefer unit or local integration tests for edge cases. Use E2E only when the
behavior depends on control-plane state, netmap updates, WireGuard routing,
identity lookup, or another tailnet node.
