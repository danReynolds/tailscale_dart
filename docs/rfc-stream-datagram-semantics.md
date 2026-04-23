# RFC: Stream and Datagram Semantics for the Canonical Runtime Transport

**Status:** Draft  
**Priority:** Follow-up implementation spec  
**Scope:** Public raw transport API shape and per-stream/per-datagram
semantics above the authenticated Dart↔Go session  
**Builds on:** [`rfc-explicit-runtime-boundary.md`](./rfc-explicit-runtime-boundary.md),
[`runtime-transport-invariants.md`](./runtime-transport-invariants.md),
[`rfc-session-transport-security.md`](./rfc-session-transport-security.md)  
**Related docs:** [`api-roadmap.md`](./api-roadmap.md),
[`api-status.md`](./api-status.md)

---

## Summary

This RFC specifies the **stream and datagram layer** of the canonical
runtime transport between Dart and the embedded Go runtime.

It defines:

- the public raw transport surface for stream and datagram APIs
- immutable endpoint and identity metadata attachment
- logical stream identifiers and stream lifecycle semantics
- the meaning of `write()`, `close()`, `abort()`, and `done`
- ordering and backpressure rules
- the concrete first public shape for UDP-like transports

It does **not** define:

- session handshake or frame authentication
- HTTP request/response behavior
- compatibility proxy mode or experimental native socket interop

The goal is to make the package's raw transport contract explicit,
debuggable, and semantically honest.

---

## V1 constants and defaults

Unless a later protocol version negotiates otherwise, v1 uses these
fixed protocol constants:

- initial per-direction stream credit: **64 KiB**
- maximum `DATA` payload per frame: **60 KiB** of application bytes
- maximum datagram payload per `DGRAM`: **60 KiB** of application bytes

V1 also requires these implementation-default policy bounds:

- maximum concurrent open streams per session: **1024**
- maximum pending inbound accepted streams per listener: **128**
- default bounded datagram receive queue per binding: **256 datagrams**

These values are intentionally conservative and easy to reason about.
They can be revisited in later versions once the substrate behavior is
proven in practice.

The 60 KiB payload ceilings are chosen to fit comfortably beneath the
session layer's 64 KiB total frame limit once framing and MAC overhead
are included.

---

## Relationship to the session/security spec

The session/security spec defines:

- how Dart and Go authenticate a runtime session
- how protocol versions and capabilities are negotiated
- how the session shuts down (`GOAWAY`)
- what counts as a session-fatal error

This document assumes that authenticated session already exists and
defines what travels **inside** it:

- streams
- datagram bindings
- stream/data lifecycle
- write/backpressure semantics

Session concerns and stream/datagram concerns remain separate layers.

---

## Goals

- Define one public raw stream contract that is not pretending to be a
  kernel `Socket`.
- Define one public datagram contract that preserves message boundaries
  honestly.
- Make endpoint metadata and identity explicit and immutable.
- Make write completion and buffer ownership precise.
- Support graceful finish and abortive termination explicitly.
- Support multiplexed streams without coupling their lifecycles.
- Make UDP-like transports package-native rather than
  `RawDatagramSocket`-shaped.

---

## Non-goals

- Reproducing all `dart:io Socket` or `RawDatagramSocket` behavior.
- Socket option parity.
- Ancillary data or control message parity.
- Promising kernel-socket address or TLS-session fidelity.
- Defining public error classes in final detail.
- Defining the Go-backed HTTP lane.

---

## Public transport surfaces

The canonical raw transport API should converge on shapes like these:

```dart
final class TailscaleEndpoint {
  const TailscaleEndpoint({
    required this.ip,
    required this.port,
  });

  final InternetAddress ip;
  final int port;
}

final class TailscaleIdentity {
  const TailscaleIdentity({
    this.stableNodeId,
    this.nodeName,
    this.userLogin,
    this.userDisplayName,
  });

  final String? stableNodeId;
  final String? nodeName;
  final String? userLogin;
  final String? userDisplayName;
}

abstract interface class TailscaleWriter {
  Future<void> write(Uint8List bytes);
  Future<void> writeAll(Stream<List<int>> source);
  Future<void> close();
  Future<void> get done;
}

abstract interface class TailscaleConnection {
  TailscaleEndpoint get local;
  TailscaleEndpoint get remote;
  TailscaleIdentity? get identity;

  Stream<Uint8List> get input;
  TailscaleWriter get output;

  Future<void> close();
  void abort([Object? error, StackTrace? stackTrace]);
  Future<void> get done;
}

abstract interface class TailscaleListener {
  Stream<TailscaleConnection> get connections;
  Future<void> close();
  Future<void> get done;
}

final class TailscaleDatagram {
  const TailscaleDatagram({
    required this.bytes,
    required this.local,
    required this.remote,
    this.identity,
  });

  final Uint8List bytes;
  final TailscaleEndpoint local;
  final TailscaleEndpoint remote;
  final TailscaleIdentity? identity;
}

abstract interface class TailscaleDatagramPort {
  TailscaleEndpoint get local;
  Stream<TailscaleDatagram> get datagrams;

  Future<void> send(
    Uint8List bytes, {
    required TailscaleEndpoint remote,
  });

  Future<void> close();
  void abort([Object? error, StackTrace? stackTrace]);
  Future<void> get done;
}
```

These public value types must have ordinary value semantics:

- `==` compares by field value
- `hashCode` is derived from field values
- `toString()` is useful for debugging without exposing secret protocol
  material

This applies to:

- `TailscaleEndpoint`
- `TailscaleIdentity`
- `TailscaleDatagram`

### Why `input` stays separate

`TailscaleConnection` should not implement `Stream<Uint8List>`
directly.

The connection object owns more than the read stream:

- endpoint metadata
- identity snapshot
- write-half lifecycle
- full-stream lifecycle
- abort semantics

Keeping `input` separate makes those responsibilities explicit.

### Listener delivery contract

`TailscaleListener.connections` is a **single-subscription** stream.

Inbound accepted streams are delivered through a bounded listener-local
backlog before they reach application code. This keeps inbound stream
admission operationally honest instead of relying on an unbounded queue
hidden behind the runtime boundary.

---

## Endpoint and identity contract

### Endpoints are first-class transport state

Every stream and datagram event must preserve:

- local endpoint metadata
- remote endpoint metadata

This is not just debugging information. The local endpoint is part of
the transport truth and may matter for routing, subnet, fallback, or
service-selection behavior.

### Identity is attached, not rediscovered

For stream classes that support authenticated peer identity, that
identity is attached as immutable metadata when the stream opens.

For accepted peer-node TCP-like streams, identity is expected to be
present at `OPEN` time and must not change for the lifetime of the
stream.

`identity` remains nullable in the public type for now because not
every supported or future transport class is guaranteed to map cleanly
to a peer-node identity.

### Datagram identity is per-delivery metadata

Datagrams do not have an `OPEN` event, so identity semantics are
different.

When a datagram identity is present, it is an immutable snapshot
associated with the source tuple as resolved by Go for that datagram
delivery. Implementations may obtain it by lookup or by cached
resolution, but the public contract is always per-datagram metadata,
not a mutable side lookup.

Datagram identity may be absent when no authenticated peer-node
identity applies or when the source tuple cannot be mapped cleanly.

For v1, datagram identity should be attached eagerly whenever the
underlying transport can resolve it cleanly.

---

## Stream model

### Stream identifiers

Each logical stream has one stable numeric `streamId` scoped to the
session.

For v1:

- Go-initiated stream IDs are even.
- Dart-initiated stream IDs are odd.
- IDs are monotonically increasing per initiator.
- stream IDs are never reused within a session, even after a stream
  terminates

Odd (Dart-initiated) IDs are reserved in the v1 protocol even if the
first implementation leaves the Dart-initiated `OPEN` path unexercised
until a feature requires it.

### Stream metadata at `OPEN`

Every stream `OPEN` frame carries immutable metadata sufficient to
construct a `TailscaleConnection`.

Minimum `OPEN` metadata:

- `streamId`
- transport kind (`tcp`, future values such as `tls_terminated`)
- local endpoint
- remote endpoint
- optional immutable identity snapshot

Additional metadata may be added compatibly in later versions, but the
fields above are the minimum semantic contract.

Successful `OPEN` also creates the initial flow-control window for that
stream.

For v1:

- each direction starts with **64 KiB** of stream credit
- this initial credit is an implicit protocol constant in v1 rather than
  an `OPEN` field
- later `CREDIT` frames extend that budget

### Concurrent stream limit

To prevent runaway stream creation, each session has a maximum number of
concurrently open streams.

For v1:

- the cap is **1024** open streams across both initiators
- an `OPEN` received beyond that cap is rejected immediately with `RST`

This limit is independent of stream ID monotonicity. Closed stream IDs
are not reused.

### Listener accept backlog

Accepted inbound streams do not bypass application scheduling. The
transport may need to hold a stream briefly before Dart consumes it from
`TailscaleListener.connections`.

For v1:

- each listener has a bounded pending-open backlog of **128** streams
- if the application is slow to consume `connections`, inbound `OPEN`s
  fill that backlog
- once the backlog is full, additional inbound `OPEN`s for that listener
  are rejected promptly with `RST`

This prevents an unbounded pending-open queue and avoids stalling the
entire session behind one slow listener.

### Stream frame kinds

The stream layer uses these semantic frame kinds:

- `OPEN`
- `DATA`
- `CREDIT`
- `FIN`
- `RST`

Session shutdown uses `GOAWAY` and is defined in the session/security
spec.

While the session is `closing` after `GOAWAY`:

- no new `OPEN` frames may be created
- existing streams may continue to exchange `DATA`, `FIN`, and `RST`
- existing streams terminate only when they complete normally, are
  reset, or the session fully closes

---

## Stream ordering and lifecycle semantics

### Ordering

Within one stream:

- bytes are delivered in order
- the receiver must not observe reordering
- write boundaries are not preserved as read boundaries

Across streams:

- no ordering relationship is guaranteed
- fairness is an implementation goal, not a semantic guarantee

### Separate send and receive state

Each stream has separate local send and receive state machines.

This spec intentionally borrows the model from QUIC-like stream
semantics:

- graceful finish is separate from abort/reset
- one direction may finish while the other remains open
- full stream completion happens only when both directions are terminal

### Send-side states

- `open`
- `finishing`
- `finished`
- `reset`

`finished` and `reset` are terminal send-side states.

State transitions:

- `open -> finishing` when local writer close is initiated
- `finishing -> finished` when local `FIN` is accepted by the local
  transport layer
- `open -> reset` or `finishing -> reset` when local abort or session
  failure occurs

### Receive-side states

- `open`
- `fin_received`
- `reset`
- `closed`

State transitions:

- `open -> fin_received` when peer `FIN` is received
- `open -> reset` when peer `RST` or session failure is observed
- `fin_received -> closed` when buffered input is fully delivered
- `reset -> closed` when local cleanup completes

The stream as a whole is terminal when:

- local send state is `finished` or `reset`, and
- local receive state is `closed`

---

## Stream frame semantics

### `OPEN`

`OPEN` creates the logical stream and attaches immutable metadata.

The receiver must either:

- accept the stream and expose it to its local runtime, or
- reject it promptly with `RST`

There is no silent “best effort” open.

### `DATA`

`DATA` carries an ordered byte range for one stream.

The receiver may:

- coalesce adjacent `DATA` frames into one `input` event
- split large `DATA` frames into multiple `input` events

But it must not:

- reorder bytes
- expose any semantic meaning from sender chunk boundaries

### `CREDIT`

`CREDIT` increases the sender's remaining send budget for one stream.

Required v1 behavior:

- each stream has independent flow-control budget in each direction
- writers must not overrun available credit
- lack of credit must backpressure writers rather than silently drop
  stream bytes

`CREDIT` for an unknown, never-opened, or already-closed stream ID is
ignored.

Implementations may also enforce session-wide memory bounds, but those
do not replace per-stream credit.

### `FIN`

`FIN` means the sender will emit no more `DATA` on that stream.

It is graceful and one-directional.

`FIN` does **not** imply the peer's direction is finished.

### `RST`

`RST` aborts the logical stream.

It is terminal for both directions at the public API level.

Expected causes include:

- explicit local `abort()`
- rejection of invalid or unsupported `OPEN`
- underlying network failure for the stream
- propagation of a session-fatal error into the stream layer

`RST` is not graceful shutdown.

### Invalid frame/state handling

Once a frame has passed session authentication, ordering, and MAC
validation, impossible stream/datagram state transitions are treated as
protocol misuse rather than benign network noise.

For v1:

- `OPEN` on a reused stream ID or with the wrong initiator parity is
  session-fatal
- `BIND` on a reused binding ID or with the wrong initiator parity is
  session-fatal
- `DATA` or `FIN` before `OPEN` is session-fatal
- `DGRAM` before `BIND` is session-fatal
- `RST` on a never-opened stream is session-fatal
- `BIND_CLOSE` or `BIND_ABORT` on a never-opened binding is
  session-fatal
- `CREDIT` on an unknown or already-closed stream is ignored
- duplicate terminal frames (`FIN`, `RST`, `BIND_CLOSE`, `BIND_ABORT`)
  for already-terminal objects are ignored

This keeps the runtime boundary strict where state divergence would
indicate a bug, while still tolerating harmless late cleanup signals.

---

## Writer contract

### `write(Uint8List bytes)`

`write()` is the fundamental backpressure and buffer-ownership
operation.

Its future completes when:

- the bytes have been accepted by the local transport layer for onward
  delivery
- the caller may safely reuse or mutate the supplied buffer
- the local transport has accounted for credit and local buffering

For v1, “accepted by the local transport layer” means:

- the stream has sufficient credit
- the write has been split into one or more `DATA` frames if needed
- those frames have been MACed
- those frames have been queued on the bounded outbound transport queue

In the first implementation, that outbound transport queue may be
realized by the carrier writer, but the enduring contract is the
transport-queue boundary rather than a specific send-pipeline topology.

Its future does **not** mean:

- the peer received the bytes
- the peer application read the bytes
- the bytes have been fully written to the carrier

The implementation may:

- copy the bytes immediately, or
- retain the caller's buffer until the future completes

The caller must treat the buffer as owned by the writer until that
future completes.

If insufficient credit or local send budget is available, `write()`
must wait rather than overrun the stream budget.

If the stream or session closes before local acceptance occurs,
`write()` fails.

If `bytes.length` exceeds the maximum per-frame `DATA` payload, the
implementation splits it into multiple `DATA` frames transparently. The
caller does not need to chunk stream writes manually.

If a single `write()` spans multiple `DATA` frames and credit runs out
mid-split, the implementation may wait for `CREDIT` between frames to
avoid overrun. The returned future does not complete until all
constituent `DATA` frames have been accepted into the outbound
transport queue.

### `writeAll(Stream<List<int>> source)`

`writeAll()` is a convenience operation that sequentially applies the
`write()` contract to each chunk from `source`.

Required behavior:

- preserve chunk order
- backpressure each chunk through `write()`
- stop consuming the source on the first write failure
- fail if the stream closes or aborts before all source chunks are
  accepted

If `source` itself terminates with error, that error propagates through
the returned future. The write half is not implicitly closed or aborted
solely because the source stream failed.

The `Stream<List<int>>` input is a convenience surface. `Uint8List` is
the efficient single-write path.

### `output.close()`

`output.close()` is the canonical graceful write-half close.

Required behavior:

- idempotent
- no further `write()` calls may succeed after close begins
- initiates local `FIN`
- completes when the local write half is permanently closed or fails

It does not wait for peer acknowledgement or peer read completion.

### `output.done`

`output.done` is transport-semantic, not controller-semantic.

It completes when the local write half is permanently terminal:

- graceful close succeeded
- the stream was reset
- the session failed
- `connection.close()` closed the write half implicitly

It completes with error if the write half terminates abortively or due
to session failure before graceful completion.

---

## Read-side contract

### `input`

`input` delivers the peer's byte stream in order.

`input` is a **single-subscription** stream.

Chunk boundaries have no semantic meaning. Consumers must treat it as a
byte sequence, not a message sequence.

### Graceful finish

If the peer sends `FIN`, then after any buffered bytes are delivered:

- `input` closes normally
- the receive side enters a terminal closed state

### Abortive finish

If the stream is reset or the session fails:

- unread buffered input is discarded
- `input` terminates with error

### Interaction with `connection.close()`

Calling `connection.close()` tells the transport that the application is
finished with the connection as a whole.

After `connection.close()` begins:

- the implementation may stop delivering additional `input` events to
  the application
- remaining peer bytes may be drained and discarded internally until
  the stream terminates

Applications that need to observe the peer's full graceful finish
should continue reading `input` and avoid calling `connection.close()`
until they are genuinely done with both directions.

### Common shutdown patterns

Graceful request/response style usage:

```dart
await connection.output.write(requestBytes);
await connection.output.close();

final chunks = <Uint8List>[];
await for (final chunk in connection.input) {
  chunks.add(chunk);
}

await connection.close();
```

“I am done; discard the rest” usage:

```dart
await connection.output.close();
await connection.close();
```

The second form may truncate unread peer data from the application's
perspective. It is only appropriate when the caller no longer cares
about the remaining input.

---

## Connection contract

### `connection.close()`

`connection.close()` is graceful full-stream close.

Required behavior:

- idempotent
- if the write half is still open, behave as if `output.close()` were
  called
- stop the connection from remaining application-readable forever
- complete when the logical stream is fully terminated

`connection.close()` may internally drain and discard peer data after
the application has indicated it is done with the stream.

If the peer later resets the stream or the session fails before full
termination, `connection.close()` fails.

This is an intentional ergonomic trade-off in v1. `connection.close()`
means “the application is done with the whole stream,” not merely “the
application is done writing.” A more symmetric duplex model with an
explicit read-cancel or dispose operation is intentionally deferred
unless implementation experience proves it necessary.

### `connection.abort([error, stackTrace])`

`connection.abort()` is abortive termination.

Public contract:

- best effort send `RST` if the session is still healthy
- fail pending writes
- terminate `input` with error
- terminate `output.done` with error if not already complete
- terminate `connection.done` with error
- discard unread input and unsent output

`abort()` is idempotent. Repeated calls after termination are no-ops.

### `connection.done`

`connection.done` is the full-stream lifecycle future.

It completes when the logical stream is permanently terminated:

- successfully on graceful full termination
- with error on reset, session failure, or abortive termination

It is intentionally defined in transport terms, not in terms borrowed
from `StreamController` or `StreamSink`.

The receive-side public contract intentionally does not expose separate
terminal state values for “graceful finish” vs “reset”. Callers observe
that distinction through normal completion vs error on `input` and
`connection.done`.

### `output.done` vs `connection.done`

- `output.done` is for write-half lifecycle: “when is my sending side
  permanently closed or failed?”
- `connection.done` is for full-stream lifecycle: “when is the logical
  stream completely over?”

Example:

```dart
await connection.output.write(bodyChunk);
await connection.output.close();
await connection.output.done; // write side is finished
await connection.done; // both directions are fully terminated
```

---

## Datagram model

Datagram transports are not streams and must not inherit stream
semantics accidentally.

### Datagram binding identifiers

Each logical datagram binding has one stable numeric `bindingId` scoped
to the session.

For symmetry with streams, binding IDs follow the same initiator rule:

- Go-initiated binding IDs are even
- Dart-initiated binding IDs are odd

The first implementation may only use Go-allocated bindings for
network-backed UDP listeners.

### Datagram frame kinds

The datagram layer uses these semantic frame kinds:

- `BIND`
- `DGRAM`
- `BIND_CLOSE`
- `BIND_ABORT`

These are intentionally separate from stream `OPEN` / `DATA` / `FIN`.

### `BIND`

`BIND` creates a logical datagram port with immutable local endpoint
metadata.

Minimum metadata:

- `bindingId`
- local endpoint
- datagram transport kind (`udp`, `udp4`, `udp6`)

### `DGRAM`

`DGRAM` carries exactly one datagram.

Required metadata:

- `bindingId`
- remote endpoint
- payload bytes
- optional immutable identity snapshot for that delivery

Message boundaries are preserved end to end within the runtime
transport.

If a `DGRAM` payload exceeds the maximum per-datagram payload size for
v1, it is invalid and must be rejected by the sender before framing.

### `BIND_CLOSE`

Gracefully releases the datagram binding.

There is no half-close concept for datagram bindings.

### `BIND_ABORT`

Abruptly releases the datagram binding and discards queued traffic.

---

## Datagram public contract

### `datagrams`

`datagrams` is a `Stream<TailscaleDatagram>`.

`datagrams` is a **single-subscription** stream.

Each event represents exactly one datagram.

Required behavior:

- preserve datagram boundaries
- preserve the delivery order observed by Go for that binding
- do not promise reliability, deduplication, or network ordering beyond
  what the underlying UDP path already provides

### Receive-side buffering and drops

Datagram bindings use bounded receive queues.

For v1, the default receive queue bound is **256 datagrams** per
binding.

If the application falls behind, the implementation may drop newly
arriving datagrams rather than stalling the entire session or allowing
unbounded memory growth.

This is intentional and consistent with datagram semantics.

The public contract should not pretend dropped datagrams are impossible.
Diagnostics for dropped counts are desirable, but the exact observability
surface is out of scope for this RFC.

### `send(Uint8List bytes, {required remote})`

`send()` completes when the datagram has been accepted by the local
transport layer for onward delivery.

For v1, that means:

- the datagram fits within the v1 payload limit
- one `DGRAM` frame has been constructed
- that frame has been MACed
- that frame has been queued on the bounded outbound transport queue

In the first implementation, that outbound transport queue may be
realized by the carrier writer, but the enduring contract is the
transport-queue boundary rather than a specific send-pipeline topology.

It does **not** mean:

- the datagram reached the peer
- the peer application read it
- the network delivered it reliably

Buffer ownership follows the same rule as stream writes:

- the caller may reuse or mutate the buffer only after the returned
  future completes

If the supplied payload exceeds the v1 datagram payload limit
(**60 KiB**), `send()` fails rather than fragmenting it into multiple
datagrams.

### `close()`

`close()` gracefully releases the binding.

After close begins:

- no further sends may succeed
- the binding may stop delivering additional datagrams to the
  application
- queued or in-flight datagrams may be discarded during shutdown

### `abort()`

`abort()` is abrupt binding termination.

It may send `BIND_ABORT` if the session is healthy, then immediately:

- fail pending sends
- terminate `datagrams` with error
- complete `done` with error

### `done`

`done` completes when the binding is permanently closed:

- successfully on graceful close
- with error on abort or session failure

### Datagram bindings during `GOAWAY`

Session `GOAWAY` stops new stream opens and should also stop creation of
new datagram bindings.

Existing datagram bindings remain valid while the session is `closing`:

- received datagrams may continue to be delivered
- `send()` may continue to succeed
- bindings terminate only when explicitly closed/aborted or when the
  session fully closes

---

## Failure mapping

### Session-fatal failure

If the authenticated session fails:

- all live streams are reset
- all live datagram bindings fail
- all pending writer/send futures fail
- all `done` futures complete with error

This restates the invariant that session-fatal failure aborts all child
transport objects.

### Stream-local failure

A stream-local failure:

- terminates that stream
- does not imply datagram bindings or other streams are invalid

### Datagram-binding-local failure

A datagram binding failure:

- terminates that binding
- does not imply any stream failure

---

## First implementation guidance

The first implementation should optimize for semantic clarity rather
than clever transport tricks.

Recommended priorities:

- keep `write()` and buffer-ownership behavior easy to reason about
- make `FIN`, `RST`, `BIND_CLOSE`, and `BIND_ABORT` obvious in logs
- prefer bounded buffering over hidden unbounded queues
- keep stream and datagram behavior visibly distinct

The implementation should preserve three bounded resource layers:

- per-stream flow-control budget
- per-listener pending-open backlog
- session-wide memory/buffer cap

The exact session-wide cap does not need to be a public API knob in v1,
but it must exist. A semantically correct implementation that allows
unbounded aggregate buffering is still operationally fragile.

In practice, the carrier-facing outbound queues are part of that
session-wide bound. Implementations must not allow unbounded
carrier-pending growth even if per-stream credit is still available.

The substrate spike should be judged against this document before
performance tuning or carrier optimization.

---

## Open questions for later refinement

- What diagnostics surface should expose dropped datagrams and reset
  reasons?
- Should later protocol versions add per-binding backpressure signals
  for datagrams, or keep bounded-drop semantics as the only model?
