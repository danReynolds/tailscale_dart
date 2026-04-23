# Runtime Transport Invariants

**Status:** Draft design note  
**Purpose:** Lock the non-negotiable truths that both follow-up transport
specs and the substrate spike must share  
**Related docs:** [`rfc-explicit-runtime-boundary.md`](./rfc-explicit-runtime-boundary.md),
[`rfc-session-transport-security.md`](./rfc-session-transport-security.md),
[`rfc-stream-datagram-semantics.md`](./rfc-stream-datagram-semantics.md)

---

## Why this note exists

The transport work now has three parallel tracks:

- session/security specification
- stream/datagram semantics specification
- a substrate spike

This note freezes the invariants that all three must share so they do
not drift.

It is intentionally short. It is not a replacement for the RFCs.

---

## Invariants

### 1. Go is the transport authority

The embedded Go runtime is the authority for:

- network interaction with the tailnet
- peer identity attachment
- local/session carrier lifecycle
- stream/session open/close decisions at the runtime boundary

Dart does not independently discover or infer transport truth from
local bridge details.

### 2. The Dart↔Go boundary is explicit

The internal substrate is a real runtime boundary, not an incidental
implementation detail.

It must therefore have:

- explicit session lifecycle
- explicit stream/datagram lifecycle
- explicit metadata attachment
- explicit authentication/integrity

No feature may rely on “it happens to work because the carrier looks
like a socket.”

### 3. Identity is attached at `OPEN`, not reconstructed later

For connection classes that support authenticated peer identity, that
identity must be attached as immutable metadata when the logical stream
opens.

Dart should not need to recover identity later by re-deriving it from:

- a loopback address
- a fake remote address
- local proxy headers not verified by the transport

### 4. Endpoint coordinates and identity are different concepts

Every transport surface must treat:

- local endpoint metadata
- remote endpoint metadata
- authenticated identity

as distinct concepts.

Do not flatten them into one “peer” object that obscures routing and
trust semantics.

### 5. `write()` completion means local acceptance, not remote receipt

For raw transport APIs, the completion of a write future means:

- the bytes have been accepted by the local transport layer for
  onward delivery
- any buffer-ownership guarantees promised by the API now hold
- backpressure has been satisfied at the local transport boundary

It does **not** mean:

- the peer has read the bytes
- the bytes reached the remote application
- the bytes were acknowledged by a tailnet peer

This invariant is fundamental to the writer contract.

### 6. Buffer ownership must be explicit

The transport contract must define when the caller may mutate or reuse
the memory backing a written buffer.

The default invariant should be:

- a caller may reuse or mutate a buffer only after the corresponding
  `write()` future completes

If the implementation copies earlier, that is an optimization, not the
contract.

### 7. Session-fatal errors abort all streams

If the authenticated runtime session fails, all live streams fail.

Examples:

- bad frame MAC
- invalid sequence number
- malformed handshake
- carrier teardown
- session-level I/O failure

There is no surviving subset of streams after a session-fatal error.

### 8. Stream-fatal errors do not imply session failure

Per-stream failures such as reset/abort affect the logical stream, not
the whole session, unless the stream failure is a symptom of a deeper
session failure.

This distinction must remain sharp in both specs and in the spike.

### 9. Carrier is not the contract

The public and protocol semantics must not depend on whether the first
implementation uses:

- loopback TCP
- Unix domain sockets
- a future native-port transport

Carrier changes may affect performance and debugging, but they must not
change the contract.

### 10. HTTP is outside the raw substrate

`http.client` is a separate Go-backed HTTP lane.

`http.expose` is an HTTP-native forwarding/identity lane.

Neither should be used to justify or validate the correctness of the
raw stream/datagram substrate.

### 11. Compatibility modes are escape hatches, not the main model

Proxy-based compatibility paths (for example via `tsnet.Loopback()`) and
platform-gated native interop are valid escape hatches.

They are not the canonical public transport model and must not drive the
core substrate design.

### 12. Session semantics and stream semantics are separate layers

Session concerns:

- handshake
- version negotiation
- capability negotiation
- authentication/integrity
- `GOAWAY`
- carrier binding

Stream concerns:

- `OPEN`
- `DATA`
- `CREDIT`
- `FIN`
- `RST`
- backpressure
- buffer ownership
- `done` semantics

The two follow-up specs should preserve that separation.

---

## Implications for the spike

The substrate spike should be judged by these invariants, not by
performance alone.

Minimum questions the spike must answer:

- Can authenticated session startup be made simple and debuggable?
- Can two concurrent streams behave correctly under backpressure?
- Is identity attached cleanly at `OPEN`?
- Are `FIN`, `RST`, and `GOAWAY` easy to reason about in logs and code?
- Are write completion and buffer reuse semantics implementable without
  ambiguity?
- Does session failure reliably abort all streams?
