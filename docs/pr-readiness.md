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
- TLS listener, Funnel, Taildrop, Serve config, Profiles, Prefs, ExitNode, and
  generic LocalAPI escape hatch

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
- Dart root tests: `dart test`
- Demo core tests: `(cd packages/demo_core && dart test)`
- Flutter demo tests: `(cd packages/demo_flutter && flutter test)`
- Go unit tests: `(cd go && go test -count=1 ./...)`
- Headscale E2E: `test/e2e/run_e2e.sh`
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

- Populate inbound TCP `TailscaleConnection.identity` from Go-side peer
  metadata or soften/remove the public promise until the field is real.
- Align lifecycle APIs: add `TailscaleListener.done`, and consider adding
  `close: true` to `TailscaleHttpResponse.writeAll` to mirror TCP output.
- Clarify `TailscaleConnection.close()` versus `abort()`. If the fd backend
  cannot distinguish graceful full-close from immediate teardown, the public
  contract should say that plainly or the methods should be reshaped before
  1.0.
- Make `up()` startup timeout configurable. The current 30 second default is
  reasonable but too rigid for slow mobile/control-plane environments.
- Tighten HTTP response/request head limits from 16 MiB to a normal HTTP header
  envelope bound, likely 64-256 KiB.
- Fix case-insensitive `Content-Length` detection in HTTP response helpers.
- Bound TCP accept-loop transient errors with backoff/escalation instead of
  emitting an unbounded 20 Hz error stream forever.
- Document and potentially tune HTTP accept backlog behavior. Go currently
  returns wire-side 503 on overflow; Dart should document that and may expose a
  backlog option later.
- Add a startup/platform probe for POSIX fd syscall bindings so unsupported or
  partially-supported platforms fail early.
- Consider a separate worker/control lane for potentially slow setup calls
  (`tcp.dial`, `udp.bind`, `http.bind`) so routine status/node calls are not
  delayed behind them.
- Reduce UDP receive-copy overhead with `Uint8List.sublistView` where safe.
- Clarify `TailscaleEndpoint.address` docs so dial/bind inputs can be broad,
  but observed connection endpoints are literal tailnet addresses.

## Known Non-Blockers

- Windows is not supported in v1. Public API entry points fail clearly before
  opening a raw transport path.
- Structured app logging hooks, cancellation tokens, and public transport-limit
  tuning are API follow-ups. The current surface is intentionally small, and the
  fd backend already enforces internal read/write bounds.
- Shelf integration should remain documentation/example-level for now to avoid
  adding a hard package dependency.
