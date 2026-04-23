# Runtime Transport Execution Plan

**Status:** Active  
**Purpose:** Turn the runtime-boundary RFC set into an execution
checklist with clear ordering, completion criteria, and current status  
**Builds on:** [rfc-explicit-runtime-boundary.md](./rfc-explicit-runtime-boundary.md),
[runtime-transport-invariants.md](./runtime-transport-invariants.md),
[rfc-session-transport-security.md](./rfc-session-transport-security.md),
[rfc-stream-datagram-semantics.md](./rfc-stream-datagram-semantics.md)  
**Related docs:** [substrate-spike-findings.md](./substrate-spike-findings.md),
[http-lane-spike-findings.md](./http-lane-spike-findings.md),
[runtime-transport-execution-journal.md](./runtime-transport-execution-journal.md),
[api-status.md](./api-status.md),
[api-roadmap.md](./api-roadmap.md)

---

## How to read this plan

This is not another architecture RFC. The architecture is already
chosen.

This plan is for executing and hardening that architecture in the right
order:

1. foundation and first slices
2. spec-conformance and hardening
3. public-surface stabilization
4. follow-on feature expansion

Checked items are either implemented or deliberately closed. Unchecked
items are the remaining work.

A checklist item is only really complete when one of these is true:

- the behavior is implemented and has direct conformance coverage
- the behavior is intentionally deferred and that deferral is written
  down explicitly

Implemented-but-untested behavior still counts as incomplete for the
purposes of RFC execution.

The companion
[runtime-transport-execution-journal.md](./runtime-transport-execution-journal.md)
records how each step actually went, including emergent changes,
reflections, blockers, and context to carry between rounds.

---

## Current summary

### Canonical architecture status

- [x] Explicit Dart↔Go runtime boundary chosen and documented
- [x] HTTP split into its own Go-backed lane
- [x] Raw TCP/UDP modeled as package-native transport types
- [x] Session/security RFC written and approved
- [x] Stream/datagram RFC written and approved
- [x] Invariants note written
- [x] Substrate spike completed
- [x] HTTP-lane spike completed

### Current implementation status

- [x] Authenticated runtime session exists in production code
- [x] Raw TCP first slice exists in production code
- [x] Raw UDP first slice exists in production code
- [x] Outgoing localhost HTTP proxy removed
- [x] `Tailscale.http` uses the Go-backed streamed/cancel-aware HTTP lane
- [x] Headscale E2E covers HTTP GET/POST/redirect/abort
- [x] Headscale E2E covers raw TCP
- [x] Headscale E2E covers raw UDP

### Honest current state

The RFCs are not just theoretical anymore. They are implemented enough
to be the real foundation.

They are **not** fully hardened yet. The remaining work is mostly:

- protocol conformance coverage
- edge-case and race hardening
- operational bounds and observability
- public-surface stabilization

---

## Phase 1: Lock the foundation

This phase is effectively complete. It is listed here so later work can
be judged against it.

### 1.1 Architecture and invariants

- [x] Write the standalone architecture RFC
- [x] Split HTTP away from the raw transport lane
- [x] Define compatibility/native-interop as non-canonical escape hatches
- [x] Freeze runtime transport invariants

### 1.2 Session/security spec

- [x] Define bootstrap contract
- [x] Define transcript-bound directional keys
- [x] Define carrier binding
- [x] Define session-fatal vs stream-fatal behavior
- [x] Define `GOAWAY`
- [x] Make v1 require fresh `Start()` after session-fatal failure

### 1.3 Stream/datagram spec

- [x] Define public transport types
- [x] Define stream lifecycle (`OPEN` / `DATA` / `CREDIT` / `FIN` / `RST`)
- [x] Define datagram lifecycle (`BIND` / `DGRAM` / `BIND_CLOSE` / `BIND_ABORT`)
- [x] Define `write()` / `send()` completion semantics
- [x] Define bounded listener backlog and datagram queue behavior
- [x] Define public close/abort semantics

### 1.4 Proof via spikes

- [x] Run substrate spike over loopback TCP
- [x] Capture substrate findings
- [x] Run HTTP-lane spike
- [x] Capture HTTP-lane findings

**Phase 1 exit:** complete.

---

## Phase 2: Build the first production slices

This phase is also largely complete. The remaining work here is cleanup,
not architecture.

### 2.1 Runtime substrate

- [x] Production runtime bootstrap/control plumbing
- [x] Authenticated runtime session in Go and Dart
- [x] Per-frame integrity in the runtime session
- [x] Loopback-TCP carrier as the first production carrier
- [x] Session shutdown integration with runtime lifecycle

### 2.2 Raw TCP

- [x] `TailscaleTcp.dial()`
- [x] `TailscaleTcp.bind()`
- [x] `TailscaleConnection` / `TailscaleListener` / `TailscaleWriter`
- [x] Peer identity attachment on accepted/opened streams where available
- [x] Headscale E2E TCP round-trip

### 2.3 Raw UDP

- [x] `TailscaleUdp.bind()`
- [x] `TailscaleDatagramPort` / `TailscaleDatagram`
- [x] Eager datagram identity attachment when available
- [x] Bind on explicit assigned Tailscale IP inside the Go runtime
- [x] Headscale E2E UDP round-trip

### 2.4 Go-backed HTTP lane

- [x] Replace outgoing localhost HTTP proxy
- [x] Stream request bodies into Go
- [x] Stream response bodies back to Dart
- [x] Redirect support
- [x] Abortable request support
- [x] Headscale E2E HTTP GET/POST/redirect/abort

### 2.5 Docs synced to implementation

- [x] README reflects package-native TCP/UDP
- [x] API status reflects current surface
- [x] API roadmap no longer describes the old socket/proxy direction as current work

**Phase 2 exit:** complete enough to shift focus to hardening.

---

## Phase 3: Spec-conformance and hardening

This is the main remaining body of work.

### 3.0 Conformance tracking rules

- [ ] Add an explicit session/security conformance matrix:
  - spec rule
  - implementation status
  - test status
  - concrete test name or gap note
- [ ] Add an explicit stream/datagram conformance matrix with the same
  fields
- [ ] Treat every currently normative RFC rule as needing at least one
  direct positive or negative test
- [ ] Treat implemented-but-untested behavior as incomplete until the
  corresponding conformance item is closed

### 3.1 Session/security conformance

- [x] Implement explicit initiator key confirmation (`SESSION_CONFIRM`)
  in the production session runtime
- [x] Add explicit tests that Dart does not mark the session open before
  `SESSION_CONFIRM` validates
- [x] Add explicit tests that replayed/stale `CLIENT_HELLO` traffic can
  at most cause attach noise or timeout burn, not a false-open session
- [x] Add explicit version-negotiation tests:
  - [x] common version succeeds
  - [x] no-common-version fails closed
- [x] Add explicit handshake-timeout tests from carrier-connected until
  session-open
- [ ] Add explicit transcript-binding tests where one transcript field
  diverges and traffic keys no longer validate
- [x] Add explicit directional-key-separation tests showing Dart→Go and
  Go→Dart keys are not interchangeable
- [x] Add explicit carrier-binding mismatch tests
- [x] Add explicit capability-negotiation tests for the v1 empty-set
  behavior, including:
  - [x] unexpected accepted capabilities are rejected
  - [x] unknown requested capabilities are rejected
- [x] Add explicit invalid session-state transition tests so the
  six-state model fails closed outside allowed transitions
- [x] Add explicit `GOAWAY` drain-timeout enforcement tests
- [x] Add direct `SERVER_HELLO` transcript-MAC tests that exercise the
  full transcript plus separator-byte behavior
- [x] Add explicit negative tests for bad handshake MAC
- [x] Add explicit negative tests for bad frame MAC
- [x] Add explicit negative tests for bad sequence numbers
- [x] Add explicit tests for malformed handshake payloads
- [x] Add explicit tests for malformed frame headers/payloads
- [x] Add bootstrap mismatch tests
- [x] Add carrier-attach timeout tests
- [x] Add session-fatal behavior tests showing all streams/bindings fail together
- [x] Add explicit test that recovery requires a fresh `Start()`
- [x] Defer optional handshake replay-cache hardening to future work
  because v1 now relies on:
  - transcript-bound directional keys
  - explicit initiator key confirmation (`SESSION_CONFIRM`)
  - post-handshake sequence/MAC validation
  and does not require nonce replay-cache enforcement as a load-bearing
  correctness mechanism

### 3.2 Stream/datagram conformance

- [ ] Add direct value-semantics tests for:
  - `TailscaleEndpoint`
  - `TailscaleIdentity`
  - `TailscaleDatagram`
- [ ] Add direct single-subscription contract tests for:
  - `TailscaleListener.connections`
  - `TailscaleConnection.input`
  - `TailscaleDatagramPort.datagrams`
- [ ] Add direct ordering tests:
  - byte ordering is preserved within one stream
  - no ordering guarantee is implied across independent streams
- [ ] Add explicit send-side state-machine transition tests
- [ ] Add explicit receive-side state-machine transition tests
- [ ] Add explicit initial-credit-at-`OPEN` tests for the v1 64 KiB
  default
- [ ] Add explicit `DATA` max-payload enforcement tests for the v1 60 KiB
  ceiling
- [ ] Add explicit datagram oversize-rejection tests for the v1 60 KiB
  ceiling
- [ ] Add explicit concurrent-stream-cap tests for the v1 1024-open limit
- [ ] Add explicit listener-backlog-overflow tests for the v1 128-pending
  limit
- [ ] Add explicit datagram-queue-cap tests for the v1 256-datagram
  default
- [ ] Add explicit eager datagram-identity-attachment tests
- [ ] Add explicit idempotency tests for:
  - `connection.close()`
  - `connection.abort()`
  - `output.close()`
  - `port.close()`
  - `port.abort()`
- [ ] Add explicit `writeAll()` source-stream-error tests showing the
  source error propagates without implicitly closing the write half
- [ ] Decide and document listener-close behavior for pending accepted
  backlog entries, then add direct tests
- [ ] Test invalid `OPEN` on reused IDs
- [ ] Test invalid `OPEN` on wrong-parity IDs
- [ ] Test `DATA` before `OPEN`
- [ ] Test duplicate terminal frames
- [ ] Test `RST` on never-opened streams
- [ ] Test invalid `BIND_CLOSE` / `BIND_ABORT` / `DGRAM` state transitions
- [ ] Test `CREDIT` on unknown/closed stream IDs is ignored
- [ ] Test `GOAWAY` cutoff precisely:
  - [ ] existing streams continue with `DATA` / `FIN` / `RST`
  - [ ] existing datagram bindings continue until closed/session-end
  - [ ] new `OPEN` is rejected
  - [ ] new `BIND` is rejected
- [ ] Test write-splitting across multiple `DATA` frames under credit exhaustion
- [ ] Test unread buffered input is discarded on reset/session failure

### 3.3 Resource-bound and load hardening

- [ ] Stress concurrent open streams up to the session limit
- [ ] Stress inbound accept backlog overflow
- [ ] Stress datagram burst/drop behavior
- [ ] Test input pause/resume interactions with buffered bytes and credit
  return
- [ ] Verify carrier-pending growth stays bounded under load
- [ ] Verify session-wide memory/buffer caps are enforced
- [ ] Add soak tests for `down()` / `logout()` / peer death under load

### 3.4 Race and shutdown hardening

- [ ] Test `abort()` during a pending `write()` and pin the future's
  completion behavior
- [ ] Test `RST` arrival while local `FIN` is in flight
- [ ] Test concurrent `connection.close()` from multiple callers
- [ ] Test `connection.close()` while `output.close()` is still pending
- [ ] Harden stream close vs abort races
- [ ] Harden `GOAWAY` vs in-flight `OPEN` races
- [ ] Harden binding close/abort vs in-flight datagrams
- [ ] Harden runtime shutdown against double-close/double-cancel paths
- [ ] Harden HTTP request cancellation vs response completion races further

### 3.5 Availability and local-race posture

- [ ] Add explicit tests around pre-auth carrier races where practical
- [ ] Decide whether any additive mitigations beyond the current posture are needed
- [ ] Document the final v1 availability posture clearly in runtime docs

### 3.6 HTTP-lane conformance

- [ ] Add explicit request-body streaming backpressure tests
- [ ] Add explicit response-body mid-stream termination tests
- [ ] Add explicit chunked-transfer tests
- [ ] Verify or document connection-reuse/pooling expectations for the
  Go-backed HTTP lane
- [ ] Decide and document WebSocket/HTTP-upgrade support or non-support
- [ ] Decide how HTTPS end-to-end conformance will be validated:
  - add real tailnet TLS coverage if the environment can support it
  - otherwise document the current validation gap explicitly

**Phase 3 exit criteria**

- Every session/security rule that is currently normative has a direct
  positive or negative test.
- Every important invalid stream/datagram state transition has a direct
  test.
- Resource bounds are exercised intentionally rather than only
  incidentally.
- Known shutdown/race bugs are closed or explicitly documented.

---

## Phase 4: Observability and operator usability

The runtime is much easier to ship once failures are visible and
classifiable.

### 4.1 Runtime diagnostics

- [ ] Define a concrete stable runtime error taxonomy covering at least:
  - [ ] unsupported version
  - [ ] bad handshake MAC
  - [ ] bad or missing session confirmation
  - [ ] bad frame MAC
  - [ ] bad frame sequence
  - [ ] malformed frame/handshake
  - [ ] stream reset
  - [ ] datagram drop
  - [ ] backlog overflow
  - [ ] buffer/resource exhaustion
- [ ] Ensure those codes surface through Dart in a way app code can act on
- [ ] Add tests for expected runtime error mapping

### 4.2 Logging and debugging

- [ ] Enforce redaction requirements from the session RFC:
  - [ ] master secret never logged
  - [ ] traffic keys never logged
  - [ ] raw MAC material never logged
- [ ] Add structured logs/counters for session-fatal events
- [ ] Add structured logs/counters for session state transitions
- [ ] Add structured logs/counters for stream resets
- [ ] Add structured logs/counters for datagram drops
- [ ] Add counters for handshake attempts, active streams, and active
  bindings
- [ ] Document which runtime failures are expected to surface in logs vs APIs

### 4.3 Findings and implementation notes

- [ ] Write a short transport-hardening findings note once Phase 3/4 settle
- [ ] Capture known deferred edge cases explicitly instead of leaving them tribal

**Phase 4 exit criteria**

- A failing runtime can be debugged without attaching a debugger.
- App code can distinguish major failure classes without string-matching.

---

## Phase 5: Public API stabilization

The public transport types are now real. This phase decides how stable
we want them to be before broadening the rest of the package.

### 5.1 Surface review

- [ ] Review every public raw transport type/method for stability
- [ ] Decide the `stream_channel` question explicitly and record the
  result
- [ ] Decide whether any currently public transport details should still be marked experimental
- [ ] Define promotion criteria from experimental to stable for any
  still-evolving raw transport surfaces
- [ ] Remove or isolate any remaining legacy assumptions that point back to socket emulation

### 5.2 Examples and docs

- [ ] Add focused examples for:
  - [ ] raw TCP client/server
  - [ ] raw UDP binding/send/receive
  - [ ] `close()` vs `output.close()` vs `abort()`
- [ ] Add a transport cookbook section to the README or docs
- [ ] Verify the RFC shutdown examples against the shipped API surface
- [ ] Ensure docs explain identity availability and nullability correctly

### 5.3 Compatibility cleanup

- [ ] Decide whether old compatibility/staging code should remain in-tree
- [ ] Fence off any leftover spike-only helpers that should stay test-only
- [ ] Document the status of non-canonical escape hatches so users do not confuse them with the mainline model

**Phase 5 exit criteria**

- Public docs teach the real transport model, not the old socket/proxy intuition.
- The team can describe which raw transport APIs are stable vs still evolving.

---

## Phase 6: Next feature expansion on top of the substrate

This phase intentionally comes after hardening. The goal is to widen the
package only once the substrate is boring.

### 6.1 Already-shipped control-plane features: clarify substrate relationship

- [ ] Decide and document whether `whois` remains on the current
  control-plane path or wants substrate-aware changes later
- [ ] Decide and document whether diagnostics remain on the current
  control-plane path or want substrate-aware changes later
- [ ] Decide and document the same for:
  - [ ] prefs
  - [ ] profiles
  - [ ] exit-node controls

### 6.2 Near-term new features

- [ ] TLS-specific listener APIs
- [ ] Funnel
- [ ] Taildrop
- [ ] Serve/Funnel config APIs

### 6.3 Deferred non-canonical paths

- [ ] compatibility proxy mode as a productized escape hatch
- [ ] experimental native socket/handle interop
- [ ] alternate carriers beyond the current loopback-TCP-first production path

**Phase 6 rule:** do not reopen the runtime-boundary architecture unless
real implementation pressure demonstrates a concrete flaw.

---

## Recommended execution order from here

If work continues immediately, the order should be:

1. Phase 3.1 session/security conformance
2. Phase 3.2 stream/datagram conformance
3. Phase 3.3 resource/load hardening
4. Phase 3.4 race/shutdown hardening
5. Phase 3.5 availability/local-race posture
6. Phase 3.6 HTTP-lane conformance
7. Phase 4 observability
8. Phase 5 public API stabilization
9. Phase 6 feature expansion

That keeps the team from widening the product surface before the
transport substrate is hardened enough to deserve it.
