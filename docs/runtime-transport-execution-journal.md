# Runtime Transport Execution Journal

**Status:** Active  
**Purpose:** Keep a running engineering journal for execution of the
runtime-boundary RFC set, including completed steps, emergent changes,
reflections, blockers, and context needed between rounds  
**Builds on:** [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md)  
**Related docs:** [rfc-explicit-runtime-boundary.md](./rfc-explicit-runtime-boundary.md),
[runtime-transport-invariants.md](./runtime-transport-invariants.md),
[rfc-session-transport-security.md](./rfc-session-transport-security.md),
[rfc-stream-datagram-semantics.md](./rfc-stream-datagram-semantics.md),
[api-status.md](./api-status.md),
[api-roadmap.md](./api-roadmap.md)

---

## How to use this journal

This is not another RFC and not a replacement for the execution plan.

The execution plan answers:

- what remains
- what order to do it in
- what "done" means

This journal records:

- what was actually worked on
- what changed during the work
- what was learned
- what became riskier or easier than expected
- what should be remembered before the next round

Each meaningful execution step should leave behind a short entry with:

- the phase/checklist item touched
- what changed
- what was validated
- what was learned
- what follow-up changed because of that learning

---

## Current snapshot

### Architecture status

- Canonical runtime-boundary architecture is implemented.
- Session/security RFC is treated as locked.
- Stream/datagram RFC is treated as effectively locked.
- TCP, UDP, and the Go-backed HTTP lane are on the mainline path.

### Current execution focus

- Phase 3 spec-conformance and hardening
- Make the execution plan behave like a real conformance checklist
- Close remaining session/security and stream/datagram coverage gaps

### Current watchpoints

- Explicit initiator key confirmation is now the load-bearing
  handshake-freshness mechanism to implement and test.
- Optional handshake replay-cache hardening is now a secondary choice,
  not the main Phase 3.1 blocker.
- HTTP-lane conformance is broader than the current E2E coverage and
  still needs explicit treatment for backpressure, termination, and TLS
  expectations.
- The remaining risk is mostly in edge cases, state-machine behavior,
  and resource-bound enforcement, not in top-level architecture.

---

## Entry template

Use this shape for future entries:

### YYYY-MM-DD — Short title

**Plan area:** `Phase X.Y`

**What changed**

- ...

**Validation**

- ...

**Findings**

- ...

**Emergent changes**

- ...

**Next**

- ...

---

## Entries

### 2026-04-22 — Execution plan created and shifted to conformance

**Plan area:** `Plan setup`

**What changed**

- Added the execution checklist in
  [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md).
- Reframed the remaining work as spec conformance, hardening,
  observability, and stabilization rather than more architecture work.

**Validation**

- Docs-only change.

**Findings**

- The architecture and first production slices were far enough along
  that the correct next step was no longer "build more" but "verify
  against the RFCs".

**Emergent changes**

- The execution plan became the primary coordination artifact for the
  next phase of work.

**Next**

- Start Phase 3.1 session/security conformance.

### 2026-04-22 — Session/security conformance started

**Plan area:** `Phase 3.1`

**What changed**

- Added production conformance tests in
  [go/runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go).
- Covered:
  - bad `SERVER_HELLO` MAC
  - bootstrap/session-generation mismatch
  - malformed `SERVER_HELLO`
  - carrier-attach timeout fail-closed behavior
  - bad frame MAC
  - bad frame sequence number
  - session-fatal teardown closing streams, listeners, bindings, and
    queues together

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- The production runtime can now be tested directly for core
  session-fatal behavior without relying on the earlier spike harness.
- Two small test-path bugs surfaced and were fixed while writing the
  tests:
  - generation mismatch needed to mutate both the canonical MAC fields
    and the decoded hello payload fields
  - `readerDone` had to be initialized in the reader-loop test fixture

**Emergent changes**

- The execution plan could now mark several Phase 3.1 items complete.
- The remaining 3.1 items became clearer: malformed frame parsing,
  recovery semantics, and broader RFC-rule coverage.

**Next**

- Continue Phase 3.1.

### 2026-04-22 — Plan tightened into a real conformance matrix

**Plan area:** `Phase 3 planning`

**What changed**

- Tightened
  [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md)
  so it now tracks normative RFC coverage rather than a generic
  hardening bucket.
- Added explicit coverage items for:
  - session/security conformance gaps
  - stream/datagram conformance gaps
  - HTTP-lane conformance
  - observability/redaction taxonomy
  - public-surface stabilization decisions
- Clarified that implemented-but-untested behavior still counts as
  incomplete.

**Validation**

- Docs-only change.

**Findings**

- The feedback was correct that the old plan structure was fine but its
  content was too coarse relative to the RFCs.
- Some gaps are only planning gaps, but others may be real
  implementation gaps. Replay resistance is the clearest example to
  verify explicitly.

**Emergent changes**

- The plan is now suitable as a measurable execution instrument.
- The next work can be chosen mechanically from unchecked normative
  items instead of by intuition.

**Next**

- Keep executing Phase 3.1 from the top.
- Distinguish clearly between:
  - implemented but untested
  - partially implemented
  - missing
  - intentionally deferred

### 2026-04-22 — Session conformance tightened around handshake and frame validation

**Plan area:** `Phase 3.1`

**What changed**

- Added more direct production conformance coverage in
  [go/runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  for:
  - unexpected selected version rejection
  - carrier-binding mismatch rejection
  - `SERVER_HELLO` transcript-MAC separator behavior
  - wrong-direction frame-key rejection
  - malformed frame header/payload handling
  - fresh-reset-required recovery behavior
- Tightened the production reader in
  [go/runtime_session.go](../go/runtime_session.go) to reject a bad frame
  protocol version explicitly.

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- Most of the next session/security conformance work is now clearly in
  the category of "missing tests for existing behavior" rather than
  "missing architecture".
- Replay resistance still stands out as the one likely real gap between
  the RFC and the implementation. Neither the Go runtime nor the Dart
  handshake path currently appears to maintain a nonce replay cache.

**Emergent changes**

- The plan can now mark more Phase 3.1 items complete:
  malformed frame coverage, directional-key separation,
  carrier-binding mismatch, transcript-MAC behavior, and the
  reset-before-recovery rule.
- Replay resistance should be treated as its own implementation-and-test
  slice rather than quietly assumed to exist.

**Next**

- Continue Phase 3.1 with:
  - replay resistance verification or implementation
  - handshake-timeout coverage
  - capability/version negotiation coverage
  - invalid session-state transition coverage

### 2026-04-22 — Session conformance extended to timeout and empty-capability behavior

**Plan area:** `Phase 3.1`

**What changed**

- Added more direct session/security tests in
  [go/runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  for:
  - handshake timeout from carrier-connected until session-open
  - rejection of unexpected accepted capabilities in the v1 empty-set
    negotiation model

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- The production Go attach path now has direct coverage for the RFC's
  handshake timeout rule.
- The v1 capability story is still only partially covered. Go rejects a
  non-empty accepted-capabilities set, but Dart-side rejection of
  non-empty requested capabilities still needs direct work.

**Emergent changes**

- The execution plan can now mark handshake-timeout coverage complete
  and split the capability-negotiation item into a closed Go-side piece
  and a remaining Dart-side piece.
- Replay resistance remains the clearest unresolved session item and
  still looks more like an implementation/RFC-alignment question than a
  pure test gap.

**Next**

- Continue Phase 3.1 with:
  - replay-resistance decision and, if needed, implementation
  - Dart-side requested-capability rejection coverage
  - fuller version-negotiation coverage
  - invalid session-state transition coverage

### 2026-04-22 — Session freshness model corrected: key confirmation, not replay cache

**Plan area:** `Phase 3.1 / session RFC alignment`

**What changed**

- Updated
  [rfc-session-transport-security.md](./rfc-session-transport-security.md)
  so the v1 handshake now treats explicit initiator key confirmation
  (`SESSION_CONFIRM`) as the load-bearing freshness step.
- Corrected the handshake direction in the RFC to match the actual
  implementation model:
  - Go sends `CLIENT_HELLO`
  - Dart replies with `SERVER_HELLO`
  - Go sends `SESSION_CONFIRM`
  - Dart only then treats the session as fully open
- Downgraded handshake nonce replay cache from a normative MUST to
  optional hardening/future work for later resumption/re-establishment
  scenarios.
- Updated
  [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md)
  so Phase 3.1 now tracks:
  - `SESSION_CONFIRM` implementation
  - false-open prevention tests
  - optional replay-cache decision as non-blocking follow-up

**Validation**

- Docs-only change.

**Findings**

- The earlier replay-cache requirement was trying to protect
  establishment freshness under a handshake that lacked final key
  confirmation.
- Once the actual problem is stated clearly, explicit initiator key
  confirmation is the cleaner and more standard fix.

**Emergent changes**

- Replay resistance no longer blocks Phase 3.1 in the same way.
- The next implementation work is now more concrete:
  land `SESSION_CONFIRM`, then test that stale/replayed hellos cannot
  create false-open sessions.

**Next**

- Implement `SESSION_CONFIRM` in the production session runtime.
- Add conformance tests that session-open occurs only after successful
  confirmation.

### 2026-04-22 — `SESSION_CONFIRM` implemented in the production session runtime

**Plan area:** `Phase 3.1`

**What changed**

- Implemented `SESSION_CONFIRM` in the production runtime session:
  - Go now queues `SESSION_CONFIRM` as the first post-handshake frame in
    [go/runtime_session.go](../go/runtime_session.go)
  - Dart now blocks session-open on validating that frame in
    [lib/src/runtime_transport.dart](../lib/src/runtime_transport.dart)
- Added direct Go conformance coverage in
  [go/runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  to prove the first post-handshake frame is `SESSION_CONFIRM` with the
  expected sequence number and MAC.

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`
- `dart analyze lib test`
- `test/e2e/run_e2e.sh`

**Findings**

- The transport-specific Headscale E2E coverage remained green:
  HTTP, raw TCP, and raw UDP still passed with the new open gate.
- A plain `dart test` run failed in the local environment with a Dart
  native-assets bundling null-check crash on macOS, which does not look
  specific to the transport changes.
- The full Headscale E2E run still hit one timeout in
  `onStateChange lifecycle up() while already running does not re-emit Running`;
  that test is outside the raw transport surface and needs separate
  triage before treating it as a transport regression.

**Emergent changes**

- The main Phase 3.1 blocker shifted again:
  `SESSION_CONFIRM` implementation is no longer the open item; the next
  work is explicit false-open prevention coverage plus cleanup of the
  remaining session-state and negotiation gaps.

**Next**

- Add direct tests that session-open is not observed before
  `SESSION_CONFIRM` validates.
- Add false-open/replayed-stale-hello coverage or document the exact
  limits of what will be tested in v1.

### 2026-04-23 — Dart-side key-confirmation coverage closed

**Plan area:** `Phase 3.1`

**What changed**

- Added a Dart-side conformance test seam by introducing
  [runtime_transport_delegate.dart](../lib/src/runtime_transport_delegate.dart) as
  the narrow runtime-transport dependency that
  [runtime_transport.dart](../lib/src/runtime_transport.dart) needs from
  the worker.
- Added targeted Dart-side session tests in
  [runtime_transport_session_test.dart](../test/runtime_transport_session_test.dart)
  covering:
  - session startup remains pending before `SESSION_CONFIRM`
  - a non-confirm first post-handshake frame is rejected
  - a stale/abandoned `CLIENT_HELLO` that never proves live key
    possession cannot create a false-open session
- Fixed the test harness to use a buffered socket reader for
  `SERVER_HELLO` instead of canceling the socket stream after the
  length-prefixed JSON, which had been invalidating the follow-on frame
  exchange.

**Validation**

- `dart test test/runtime_transport_session_test.dart`
- `dart analyze lib test`

**Findings**

- The earlier failure here was in the test harness, not the runtime:
  canceling the socket stream after reading `SERVER_HELLO` made the fake
  Go peer incapable of continuing into framed transport bytes.
- With the buffered harness in place, the Dart runtime behaved as
  intended:
  - `RuntimeTransportSession.start()` does not complete before
    `SESSION_CONFIRM`
  - a wrong first post-handshake frame fails closed
  - a valid `CLIENT_HELLO` without live key confirmation only produces
    attach noise / closed-session failure, not a false-open session

**Emergent changes**

- The `SESSION_CONFIRM` decision is now backed by direct Go-side and
  Dart-side conformance coverage rather than only by reasoning and RFC
  updates.
- The remaining Phase 3.1 work is now more clearly concentrated in
  negotiation/state-machine coverage rather than in handshake-freshness
  uncertainty.

**Next**

- Continue Phase 3.1 with:
  - version-negotiation coverage
  - Dart-side requested-capability rejection
  - invalid session-state transition coverage
  - `GOAWAY` drain-timeout enforcement

### 2026-04-23 — Dart responder now enforces version/capability negotiation

**Plan area:** `Phase 3.1`

**What changed**

- Tightened
  [runtime_transport.dart](../lib/src/runtime_transport.dart) so the
  Dart responder now validates the incoming `CLIENT_HELLO` shape before
  it proceeds with the authenticated handshake:
  - `type` must be `CLIENT_HELLO`
  - `sessionProtocolVersions` must include v1
  - `requestedCapabilities` must be empty in the v1 empty-capability
    model
- Extended
  [runtime_transport_session_test.dart](../test/runtime_transport_session_test.dart)
  with direct Dart-side conformance tests covering:
  - advertised version lists that include v1 succeed
  - unsupported advertised versions fail closed
  - non-empty requested capabilities fail closed

**Validation**

- `dart test test/runtime_transport_session_test.dart`
- `dart analyze lib test`

**Findings**

- This was a real implementation gap, not just a missing test:
  the Dart responder had been authenticating the incoming `CLIENT_HELLO`
  MAC without actually enforcing the advertised version list or the v1
  requested-capability contract.
- The fix is local and clean: the responder now rejects those cases
  before it derives/uses the transcript for an open session.

**Emergent changes**

- Capability-negotiation coverage for the v1 empty-set is now closed on
  both sides.
- Version-negotiation coverage is now explicitly closed rather than
  relying on generic successful-handshake tests.

**Next**

- Continue Phase 3.1 with:
  - invalid session-state transition coverage
  - `GOAWAY` drain-timeout enforcement

### 2026-04-23 — Invalid session-state transitions tightened and covered

**Plan area:** `Phase 3.1`

**What changed**

- Tightened the Go runtime in
  [runtime_session.go](../go/runtime_session.go) so new TCP listeners
  and new TCP streams are only allowed while the session is `open`.
  This fixes a real bug where `dialTCP()` and `registerStream()` were
  still allowing new `OPEN`s during `closing`.
- Added direct Go conformance tests in
  [runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  covering:
  - `attach()` rejected outside `idle`
  - `bindTCP()` rejected outside `open`
  - `dialTCP()` rejected outside `open`
  - `registerStream()` rejected in `closing`
  - `bindUDP()` rejected outside `open`

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- This was not just a missing-test issue. The runtime really was too
  permissive in `closing`, which contradicted both the RFC and the
  earlier spike finding that `GOAWAY` stops new `OPEN`/`BIND`
  creation while letting existing streams/bindings drain.
- The state-machine item is now much closer to the RFC’s intended
  contract because wrong-state entry points are explicitly fenced rather
  than left to higher-level callers.

**Emergent changes**

- The remaining Phase 3.1 work is now concentrated in graceful-shutdown
  behavior (`GOAWAY` drain timeout) rather than in open-state
  correctness.

**Next**

- Continue Phase 3.1 with:
  - `GOAWAY` drain-timeout enforcement
  - optional handshake replay-cache hardening decision

### 2026-04-23 — `GOAWAY` drain timeout implemented and covered

**Plan area:** `Phase 3.1`

**What changed**

- Added a real graceful-closing path in
  [runtime_session.go](../go/runtime_session.go):
  - receiving `GOAWAY` now moves the session to `closing`
  - existing listeners are closed so no new admissions occur
  - a drain timer starts using the RFC’s 30-second default
  - the session transitions to `closed` once the drained set is empty,
    or is forced closed with `goaway_drain_timeout` if it lingers too
    long
- Added direct conformance coverage in
  [runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  for:
  - immediate close when `GOAWAY` arrives with nothing left to drain
  - forced close after a shortened test drain timeout when a lingering
    stream keeps the session in `closing`
- Fixed a real reader-loop bug uncovered by the new tests:
  graceful close could nil out `rt.conn` while the reader loop was still
  iterating, causing a nil dereference instead of a clean exit

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- This step was not just a missing test. The runtime genuinely lacked
  the RFC’s drain-timeout behavior, and the new tests exposed a
  lifecycle race in the reader loop while closing.
- The session state machine is now materially closer to the RFC:
  `open -> closing -> closed` is no longer just a label change; it has
  real timeout and shutdown behavior behind it.

**Emergent changes**

- Phase 3.1 is now mostly reduced to the optional replay-cache hardening
  decision rather than any obvious missing normative shutdown behavior.

**Next**

- Decide whether optional handshake replay-cache hardening is worth
  implementing in v1 or should remain explicitly deferred.

### 2026-04-23 — Optional handshake replay-cache hardening deferred

**Plan area:** `Phase 3.1`

**What changed**

- Closed the remaining Phase 3.1 replay-cache decision as an intentional
  v1 deferral in
  [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md).

**Validation**

- Docs-only change.

**Findings**

- With the corrected session model, handshake freshness in v1 is now
  carried by:
  - fresh per-`Start()` secret material
  - transcript-bound directional traffic keys
  - explicit initiator key confirmation via `SESSION_CONFIRM`
  - post-handshake sequence and MAC checks
- That means a nonce replay cache is no longer a load-bearing
  correctness mechanism for the current one-session-per-generation
  design. It remains optional hardening / future work if resumption or
  same-generation re-establishment is added later.

**Emergent changes**

- Phase 3.1 is effectively closed as a hardening/conformance phase
  rather than still carrying one unresolved protocol decision.

**Next**

- Move on to Phase 3.2 stream/datagram conformance.

### 2026-04-23 — Go-side graceful stream finalization cleaned up before Phase 3.2

**Plan area:** `Phase 3.2 prep`

**What changed**

- Tightened the Go runtime stream lifecycle in
  [runtime_session.go](../go/runtime_session.go) so graceful
  two-sided `FIN` completion now removes a stream from the live session
  set instead of leaving it resident until reset or session teardown.
- Added focused regression tests in
  [runtime_session_conformance_test.go](../go/runtime_session_conformance_test.go)
  covering:
  - a stream is not removed after only one graceful half reaches
    terminal state
  - a stream is removed once both halves have finished gracefully
  - graceful stream removal can let a `closing` session reach `closed`
    without relying on drain timeout

**Validation**

- `go test ./... -run 'TestRuntimeTransportSession'`
- `go test ./...`

**Findings**

- This was the main tactical compromise left behind by the 3.1
  `GOAWAY` work: session-level graceful drain existed, but Go-side
  streams still had no real graceful finalization/removal path.
- Fixing that now keeps the session drain model honest before broader
  stream/datagram conformance work begins.

**Emergent changes**

- The runtime is now in a better place to start Phase 3.2 because
  session closure no longer depends as heavily on reset paths or drain
  timeout for streams that actually complete cleanly.

**Next**

- Start Phase 3.2 stream/datagram conformance from the top of the plan.
