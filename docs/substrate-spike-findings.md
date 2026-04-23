# Substrate Spike Findings

Date: 2026-04-22

This note records the outcome of the isolated substrate spike built against:

- [docs/runtime-transport-invariants.md](/Users/dan/Coding/tailscale_dart/docs/runtime-transport-invariants.md)
- [docs/rfc-session-transport-security.md](/Users/dan/Coding/tailscale_dart/docs/rfc-session-transport-security.md)
- [docs/rfc-stream-datagram-semantics.md](/Users/dan/Coding/tailscale_dart/docs/rfc-stream-datagram-semantics.md)

## Scope

The spike intentionally does **not** integrate with the public package API yet.

It adds:

- spike-only native entry points
- a Go-side isolated session runtime over loopback TCP
- a Dart test harness that acts as the carrier listener and protocol peer
- end-to-end tests for handshake, streams, datagrams, flow control, backlog, and shutdown

## What Worked

The canonical substrate model held up well in an end-to-end implementation:

- Authenticated session startup over a local carrier worked cleanly.
- Transcript-bound HKDF-derived directional traffic keys were straightforward to implement on both sides.
- Per-frame MAC verification and 64-bit sequence enforcement were easy to reason about.
- Metadata-at-`OPEN` worked cleanly for both Go-initiated and Dart-initiated streams.
- Fixed initial stream credit plus `CREDIT`-driven continuation gave the intended local-acceptance backpressure behavior.
- Bounded listener backlog and bounded datagram receive queues mapped naturally to prompt `RST` and bounded-drop behavior.
- Separate stream and datagram frame families kept the implementation simpler than a more unified model would have.

## Spec Adjustment Confirmed by the Spike

One semantics correction mattered during implementation:

- After `GOAWAY`, the session must still permit `DATA`, `FIN`, `RST`, and `DGRAM` for already-open streams and bindings.
- Only creation of new logical objects (`OPEN`, `BIND`) should be rejected once the session is closing.

The spike initially blocked all queued writes once the session entered `closing`. That was wrong relative to the intended model and has already been corrected in the spike runtime.

## Operational Notes

- There is a small post-handshake race before the Go side transitions the session state to `open`. The harness now waits for that transition explicitly before driving commands.
- Using an explicit buffered reader over a single socket subscription on the Dart side was important. Repeated ad hoc reads would have violated the single-subscription stream contract.
- The current spike uses loopback TCP only. That was sufficient to validate session and stream/datagram semantics without prematurely optimizing carrier choice.

## Confidence Gained

The spike materially reduces architectural risk.

What now looks validated:

- explicit session/security split from stream/datagram semantics
- local-acceptance write/send semantics
- bounded resource model at multiple layers
- `GOAWAY`/closing semantics for existing vs new logical objects
- metadata attachment at the transport boundary instead of later lookup

## Next Implementation Steps

1. Turn the spike runtime into a real internal session runtime inside the package lifecycle.
2. Replace spike-only FFI control hooks with real bootstrap/control plumbing.
3. Introduce production transport objects on top of the session runtime.
4. Run a separate Go-backed HTTP lane spike, since that remains a distinct architectural lane.
