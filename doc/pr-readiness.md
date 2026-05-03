# PR Readiness: fd-backed transport

## Scope

This PR replaces the abandoned universal authenticated-session data plane with
the capability-first backend described in
[`rfc-runtime-data-plane-backends.md`](rfc-runtime-data-plane-backends.md).

In scope:

- package-native TCP connection/listener types
- POSIX fd-backed TCP dial/listen/accept
- package-native UDP datagram binding types
- POSIX fd-backed UDP bind/send/receive
- HTTP client and inbound HTTP server bodies backed by private fd streams
- LocalAPI one-shots needed by the core demo: nodes, whois, diagnostics, and
  TLS-domain preflight
- reusable demo harness and Flutter validation app

Out of scope:

- the old session/security protocol and stream multiplexer
- Windows raw TCP/UDP backend
- TLS listener, Funnel, Taildrop, Serve config, Profiles, and generic LocalAPI
  escape hatch

## Reviewer Model

Read the PR as a backend simplification, not as a deletion of security work.
On POSIX, the fd is the local capability. The kernel fd table provides the local
authority boundary, so the raw data plane does not need a loopback-carrier
handshake, frame MACs, replay cache, or stream multiplexer.

HTTP remains a semantic lane, not a raw socket emulation layer. Go owns outbound
HTTP execution through `tsnet` because Go's HTTP stack already handles
redirects, pooling, chunking, TLS, and request semantics. Inbound HTTP now uses
the same capability-first data movement: Go accepts the tailnet request and
hands Dart private fd-backed request/response body streams.

## Current Validation

Manual validation:

- macOS Flutter demo probe: ping, whois, HTTP GET/POST, TCP echo, UDP echo
- iOS Flutter demo probe: ping, whois, HTTP GET/POST, TCP echo, UDP echo
- Android Flutter demo probe: ping, whois, HTTP GET/POST, TCP echo, UDP echo

Automated validation to run before merge:

- Dart static analysis: `dart analyze`
- Dart root tests: `dart test` (unit + local integration; E2E skips unless
  Headscale env vars are set)
- Demo core tests: `(cd packages/demo_core && dart test)`
- Flutter demo tests: `(cd packages/demo_flutter && flutter test)`
- Go unit tests: `(cd go && go test -count=1 ./...)`
- Headscale E2E: `test/e2e/run_e2e.sh`
- Local PR gate: `tool/test_pr_gate.sh`
- Local full suite: `tool/test_local_full.sh`
- Whitespace check: `git diff --check`

Run Dart test commands serially. Running multiple `dart test` invocations in
parallel can race the macOS native-assets bundler and fail before tests execute.

Latest local readiness sweep, 2026-04-25:

- `dart analyze`: passed
- `dart test`: passed
- `(cd packages/demo_core && dart test)`: passed
- `(cd packages/demo_flutter && flutter test)`: passed
- `(cd go && go test -count=1 ./...)`: passed
- `HEADSCALE_PORT=18080 test/e2e/run_e2e.sh`: passed
- `git diff --check`: passed
- generated build artifact check: passed

`HEADSCALE_PORT=18080` was used because another local process was already
listening on port 8080.

Coverage added in the readiness pass:

- fd transport: bidirectional byte movement, buffer ownership, half-close,
  idempotent close, write bounds, single-subscription input, pause-aware reads,
  and large-payload integrity
- HTTP fd client: response-head parsing, body bytes following the head in the
  same fd chunk, closed-before-header failure, invalid head length failure,
  native response-head errors, late request-body errors, and response-body close
  ordering
- UDP fd binding: message preservation, oversize rejection,
  single-subscription datagrams, malformed envelope errors, and value semantics

## Remaining Before Merge

- Re-run the full validation sweep above if additional review edits land.
- Keep generated Flutter/Dart build artifacts out of the PR.
- Decide whether Linux real-tailnet validation is required for this PR or can
  land as follow-up. The POSIX backend is implemented for Linux, but manual
  device validation so far focused on macOS/iOS/Android.

## 1.0 Launch Blockers

- Replace the current two-isolates-per-fd backend with a bounded shared POSIX
  fd reactor, or explicitly replace it with another bounded-I/O backend. See
  [`rfc-shared-fd-reactor.md`](rfc-shared-fd-reactor.md). The current backend is
  correct for validation and moderate traffic, but isolate count scales with
  active fd count and should not be the final high-concurrency server story.

## Accepted PR Feedback To Address

These are worth doing after the current review fixes and before declaring the
core API production-ready. TLS and Funnel are intentionally omitted here because
they have not been redesigned for the fd-backed architecture yet.

- Consider a separate worker/control lane for potentially slow setup calls
  (`tcp.dial`, `udp.bind`, `http.bind`) so routine status/node calls are not
  delayed behind them.
- Decide whether HTTP accept backlog should become configurable. The current
  wire-side overflow behavior is documented as HTTP 503.

Recently addressed from this feedback:

- `TailscaleConnection.identity` now documents that POSIX fd-backed accepted
  TCP does not attach identity yet; callers should use `whois(remote.address)`
  for authorization.
- `TailscaleListener.done` was added, and `TailscaleHttpResponse.writeAll`
  gained `close: true`.
- `TailscaleConnection.close()` / `abort()` docs now state the fd backend's
  local shutdown semantics plainly.
- `up(timeout: ...)` is configurable.
- HTTP fd head envelopes are capped at 256 KiB instead of 16 MiB.
- Response helpers detect `Content-Length` case-insensitively.
- TCP accept-loop transient errors now back off and escalate after repeated
  failures.
- UDP envelope decode avoids extra `sublist` copies where safe.
- `TailscaleEndpoint.address` docs distinguish broad dial/bind inputs from
  observed runtime endpoints.
- `Tailscale.init()` now probes the POSIX fd syscall surface once on startup so
  unsupported or partially-supported platforms fail before first transport use.

## Known Non-Blockers

- Windows is not supported in v1. Public API entry points fail clearly before
  opening a raw transport path.
- Structured app logging hooks, cancellation tokens, and public transport-limit
  tuning are API follow-ups. The current surface is intentionally small, and the
  fd backend already enforces internal read/write bounds.
- Shelf integration should remain documentation/example-level for now to avoid
  adding a hard package dependency.
