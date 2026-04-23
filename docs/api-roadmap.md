# API roadmap

This file tracks the next public-surface work after the runtime-boundary
RFC set and the first production substrate slices.

For the ordered execution checklist for the runtime-boundary RFC work,
see [runtime-transport-execution-plan.md](./runtime-transport-execution-plan.md).

## Recently completed

- Replaced the outgoing localhost HTTP proxy with a Go-backed `http.Client`
  lane.
- Implemented the authenticated Dart↔Go runtime session.
- Implemented raw TCP on top of that substrate with `TailscaleConnection`
  and `TailscaleListener`.
- Implemented raw UDP on top of that substrate with
  `TailscaleDatagramPort`.
- Added Headscale E2E coverage for:
  - Go-backed HTTP GET/POST/redirect/abort
  - raw TCP round-trip
  - raw UDP round-trip

## Near-term priorities

### 1. Tighten the public transport APIs

The first transport slice is live. Next improvements should stay within
the current architecture, not reopen it.

Candidate follow-on work:

- document more example usage for `TailscaleConnection` and
  `TailscaleDatagramPort`
- expose more structured diagnostics for resets/drops/runtime transport
  failures
- review whether additional convenience helpers belong on the public
  transport types

### 2. Harden the production substrate

The substrate is now implementation, not spike code. Remaining work is
hardening and observability.

Focus areas:

- tighter runtime diagnostics around stream resets and datagram drops
- more failure-path tests
- carrier refinements beyond the current loopback-TCP first path
- operational guardrails around memory/buffer bounds

### 3. Decide the next user-facing surface areas

The canonical direction is still:

- standard `http.Client` for HTTP
- package-native transport types for raw TCP/UDP
- higher-level APIs where that is the more honest fit

The next major additions should be chosen from:

- `whois`
- diagnostics
- preferences
- profiles
- exit-node controls

### 4. Leave these out until there is product pressure

These remain intentionally deferred:

- socket-fidelity interop as a canonical API
- TLS/Funnel-specific public APIs
- Taildrop
- Serve/Funnel config management
- resume/rekey/multi-session substrate work

## Guardrails

As the package expands, keep these decisions stable unless there is a
very strong reason to revisit them:

- raw transports stay package-native, not `dart:io Socket` emulation
- HTTP stays a separate Go-backed lane
- control-plane calls use direct FFI/RPC-style operations
- stream/datagram payloads ride the authenticated runtime substrate
- compatibility proxying and native-handle interop remain escape hatches,
  not the mainline design
