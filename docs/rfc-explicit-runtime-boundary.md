# RFC: Explicit Runtime Boundary for Stream Transports

**Status:** Draft  
**Priority:** Long-term architecture  
**Scope:** Public transport API shape and the internal Dart↔Go runtime
boundary  
**Related docs:** [`api-roadmap.md`](./api-roadmap.md),
[`api-status.md`](./api-status.md)

---

## Summary

`package:tailscale` embeds the Tailscale networking engine in Go and
exposes it to Dart applications. Today, the package is shaped around a
simple assumption:

> if Go accepts or dials a network connection, Dart should usually see a
> normal `dart:io` socket.

This RFC proposes changing that assumption.

### Decision

- Keep standard Dart types only where their semantics are genuinely
  preserved.
- Introduce package-native transport types for raw stream and datagram
  APIs that cross the Dart↔Go runtime boundary.
- Build one explicit internal streaming substrate between Dart and Go
  instead of continuing to add feature-specific bridge mechanisms.

In practice, this means:

- `http.client` remains a standard `http.Client`, implemented through a
  Go-backed HTTP lane rather than through the raw stream transport API.
- control-plane APIs (`up`, `down`, `status`, `whois`, diagnostics,
  prefs, profiles, etc.) remain ordinary Dart APIs.
- raw `tcp`, `tls`, and `udp` APIs move to explicit Tailscale-native
  transport types rather than `Socket`, `ServerSocket`, or
  `RawDatagramSocket`.
- the package may still expose explicit non-canonical escape hatches for
  compatibility proxying and platform-gated native socket interop

This is a long-term architecture decision. It is intended to be the
foundation the package grows from, not just a temporary fix.

---

## Background

### What the package is doing today

`package:tailscale` runs one embedded Tailscale node inside the current
Dart process. The Go runtime owns the actual networking engine. Dart is
the host application runtime.

Some APIs fit that arrangement naturally:

- start and stop the node
- fetch status
- query peer identity
- make outbound HTTP requests

Other APIs are more awkward, especially raw stream transports.

For example, an inbound connection currently looks like this in
principle:

1. Go accepts a real tailnet connection.
2. Go forwards that connection into Dart over a local bridge.
3. Dart receives a local object that looks like a normal socket.

That model is convenient, but it hides a real boundary:

- Go saw the real network connection.
- Dart saw a bridged representation of it.

This RFC is about making that boundary explicit in the architecture.

### Why revisit this now

This project is still early enough that transport APIs are not yet
fully locked. That makes now the cheapest point to choose a principled
long-term shape, before more public surface area depends on the current
socket-first assumption.

---

## Problem

The current design has two different issues:

### 1. Security issue: unauthenticated local handoff

When inbound traffic is forwarded from Go into Dart over a local bridge,
that handoff must be authenticated. Otherwise, a co-resident local
process can impersonate the bridge and send bytes that look like
tailnet traffic to the Dart side.

Earlier RFCs focused on this problem directly and proposed either:

- per-connection attestation envelopes and signed headers, or
- a single authenticated local session protocol

Those were useful steps, but they still assumed the same public API
goal: keep treating bridged transports as if they were plain
`dart:io` transports.

### 2. Semantic issue: a bridged transport is not actually a plain socket

Even if the local handoff is authenticated, a bridged transport still
does not behave exactly like a native Dart socket.

Examples of semantics that may no longer be faithfully preserved:

- `remoteAddress` / `remotePort`
- `localAddress` / `localPort`
- socket option APIs
- raw control messages
- `SecureSocket`-specific TLS state such as peer certificates
- exact identity and lifetime guarantees tied to a kernel socket

If the package cannot preserve those semantics honestly, it should not
promise them through a standard socket API.

That semantic mismatch is the deeper architectural issue.

---

## Design principles

### 1. Prefer semantic honesty over familiar wrappers

A package-native transport type that accurately describes what the user
has is better than a familiar standard type that quietly lies about its
semantics.

### 2. Keep standard Dart types where they are still true

This RFC does **not** argue for replacing all standard Dart APIs.

The package should continue to use standard Dart types when the
semantics remain faithful. Examples:

- `http.Client`
- normal Future/Stream-based control-plane APIs
- plain immutable value types for status and peer metadata

### 3. Make the Dart↔Go boundary explicit

This package is not “just Dart networking” and not “just Go
networking.” It is a cross-runtime system living inside one process.

That boundary needs:

- explicit transport semantics
- explicit peer metadata
- explicit lifecycle rules
- explicit authentication

It should not remain an implementation detail hidden behind ad hoc
bridge patterns.

### 4. Separate public API shape from backend optimization

The long-term public API should not depend on whether the internal data
plane uses:

- loopback TCP
- Unix domain sockets
- native-port message passing
- direct socket handoff on some platforms

Those are backend decisions. The public model should stay stable across
them.

---

## Research findings

### Standard Dart precedents already exist for explicit bidirectional channels

The [`stream_channel`](https://pub.dev/packages/stream_channel) package
defines a `StreamChannel` as a two-way communication primitive and is
used by Dart tooling to abstract over different carriers. This is a
strong ecosystem precedent for using an explicit channel abstraction
instead of pretending everything is a socket.

### Other embedded transport libraries use explicit native types

For example, `flutter-webrtc` exposes `RTCDataChannel`, not `Socket`.
That is the right precedent when the transport semantics come from an
embedded networking system rather than directly from the OS socket
layer.

### `http.client` can remain standard

Dart application code is already expected to use
[`package:http`](https://pub.dev/packages/http) in most cases, and
`http.BaseClient` only requires a `send()` implementation. Separately,
`tsnet.Server` already has a tailnet-aware HTTP client on the Go side.

That means `http.client` can remain a standard `http.Client` while
being implemented as a Go-backed HTTP lane. It does not need a
localhost HTTP proxy and does not need to be forced onto the same
public transport abstraction as raw streams.

### Direct socket handoff is not a solid universal basis today

There are promising primitives:

- `libtailscale` exposes listener/connection handles and remote address
  lookup
- Dart exposes `ResourceHandle`, `SocketControlMessage`, and `NativeApi`

But those pieces do not yet add up to a clean, standard,
cross-platform story for always turning bridged connections into true
Dart sockets.

So the architecture should not depend on that path.

### `tsnet.Loopback()` is a viable compatibility escape hatch

`tsnet` already exposes `Loopback()` that can provide a loopback routing
server, including a SOCKS5 proxy onto the tailnet and LocalAPI access
credentials. That makes it a strong fit for a compatibility lane:

- useful for third-party libraries that need a conventional proxy or
  local network endpoint
- clearly separate from the semantically honest canonical API
- valuable without forcing proxy/socket semantics into the main public
  transport model

### HTTP identity and raw stream identity are different problems

Tailscale Serve uses HTTP headers to propagate request identity. That
is a useful reminder that HTTP and raw stream identity do not need the
same public abstraction.

### Proven multiplexers are a better semantic template than ad hoc design

The canonical internal substrate should borrow semantics from proven
systems such as QUIC streams and stream multiplexers used in systems
like libp2p:

- stable stream identifiers
- separate send/receive lifecycle
- explicit graceful finish vs reset
- negotiated session setup
- credit-based flow control

This does **not** mean literally implementing QUIC or a libp2p
multiplexer in-process. It means using their stream/session semantics as
the design template rather than inventing a fresh model casually.

### Upstream identity data is richer than endpoint coordinates

Tailscale LocalAPI `WhoIs` responses carry both node and user identity
information, and successful responses include non-nil node and user
profile data. That is a strong signal that raw transport APIs should
model endpoint coordinates and authenticated identity as separate
concepts rather than flattening them into one peer object.

---

## Decision

### Public API

#### Keep standard types for:

- `http.client`
- control-plane methods and status/identity queries
- any API whose semantics are still ordinary Dart semantics

#### Introduce package-native types for:

- `tcp.dial`
- `tcp.bind`
- `tls.bind` or an equivalent Go-terminated secure listener API, once
  its semantics are frozen clearly
- `udp.bind`
- future stream-heavy or datagram-heavy features such as Taildrop and
  richer Serve transport APIs

#### Non-canonical escape hatches

The canonical API should not be the only possible API.

Two explicit escape hatches are worth keeping in the design:

1. **Compatibility lane**
   - built on `tsnet.Loopback()` and related proxy/local API support
   - intended for libraries or integrations that need conventional proxy
     semantics rather than native transport types
   - not the canonical application-facing transport model

2. **Experimental native interop lane**
   - platform-gated, best-effort socket/handle interop
   - only where Dart/runtime support is good enough
   - optimization or integration aid, not the architectural foundation

### Internal architecture

Adopt one explicit internal streaming substrate between Dart and Go for
stream-oriented traffic.

That substrate must support:

- bidirectional byte streams
- per-stream metadata
- explicit stream and session lifecycle semantics
- backpressure
- authentication and integrity at the runtime boundary
- multiplexing or an equivalent way to manage multiple logical streams

This replaces the strategy of growing per-feature local bridge
mechanisms indefinitely.

Its session and stream semantics should be modeled on proven logical
transport systems rather than improvised per feature. QUIC-like and
stream-multiplexer-like semantics are the right reference point even if
the actual carrier and implementation are much simpler.

### Complexity acknowledgement

This decision does **not** make the underlying implementation simple.

An internal substrate with:

- multiple logical streams
- metadata-bearing stream opens
- half-close and full-close semantics
- backpressure
- authenticated control frames

is, in substance, a multiplexed session protocol.

That complexity is real. It includes risks such as:

- stream lifecycle races
- teardown ordering bugs
- buffering and backpressure mistakes
- head-of-line blocking if the carrier or framing is poorly designed

This RFC is still choosing that direction deliberately.

Why:

- the complexity already exists implicitly in the bridge-preserving
  alternatives
- keeping it internal behind one explicit contract is cleaner than
  reproducing it separately in TCP, TLS, UDP, and future stream features
- the package is better served by one honest internal transport than by
  a growing set of feature-specific bridge tricks

The implementation must therefore be treated as a first-class transport
project, not as a small refactor.

---

## Proposed public API direction

The exact method and type names are still open to iteration, but the
shape should look roughly like this:

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
```

Then the raw transport API would look more like:

- `tsnet.tcp.dial(...) -> Future<TailscaleConnection>`
- `tsnet.tcp.bind(...) -> Future<TailscaleListener>`
- `tsnet.tls.bind(...) -> Future<TailscaleListener>` only once it is
  clearly defined as a Go-terminated secure listener, not a Dart-native
  TLS socket API

UDP should also become package-native rather than pretending to be a
plain `RawDatagramSocket`.

### Why this shape

This makes several important things explicit:

- a connection has both local and remote endpoint metadata
- authenticated identity is distinct from transport coordinates
- the connection is a runtime-level stream abstraction, not an OS socket
- half-close and abort are transport features, not incidental socket
  methods
- the package, not the user, owns the bridge semantics

`TailscaleWriter` is intentionally transport-shaped rather than reusing
`StreamSink`. Backpressure is expressed through `Future<void>`-returning
write methods, and writer shutdown semantics are explicit rather than
inherited from a more generic async primitive.

The writer owns the write-half lifecycle:

- `output.close()` is the canonical graceful write-half close
- `output.done` represents the write half being permanently closed or
  failed
- `connection.close()` is the graceful full-stream close
- `connection.abort()` is the abortive termination path

### Identity and endpoint contract

Identity and routing metadata should be treated as first-class transport
state.

- `remote` is the source endpoint for the connection or datagram flow.
- `local` is the destination endpoint inside the tailnet routing model,
  not just a debugging convenience.
- `identity` is an immutable authenticated snapshot when available.

Preserving `local` is important for correctness, not just completeness.
Advanced tsnet behavior such as fallback TCP handling is defined in
terms of source and destination tuples, so destination semantics matter
for routing and service behavior.

The type of `identity` stays nullable in this RFC because not every
future transport case is yet proven to map cleanly to a successful
WhoIs-style identity lookup. However, the intent is stronger than a
generic optional bag:

- accepted peer-node connections are expected to open with an immutable
  authenticated identity snapshot
- nullability is a conservative API choice until every supported
  connection class is proven to provide one

The `capabilities` field in `TailscaleIdentity` should be treated as a
follow-up concern rather than part of the first public transport
contract. Upstream identity data includes capabilities, but this RFC
does not freeze an unstructured capability surface in the initial API.

---

## HTTP direction

### `http.client`

Keep it standard.

Internally, implement it as a Go-backed HTTP lane:

- public surface remains `package:http`
- request execution happens through Go using the embedded tailnet-aware
  HTTP client
- the implementation does not depend on the raw stream transport API or
  on preserving fake socket semantics

This removes the current localhost HTTP proxy without needing a custom
public HTTP client abstraction.

This RFC does **not** claim a broad HTTP performance improvement beyond
that cleanup. The most common expected use case for the package is HTTP
over the tailnet, and its main concrete transport win here is removal of
the localhost HTTP proxy in `http.client`.

This specific Go-backed HTTP-lane design still needs a prototype. The
earlier local spike validated a different path (`connectionFactory` +
socket interop), not the Go-backed `http.BaseClient.send` path this RFC
now prefers.

### `http.expose`

Keep it HTTP-native.

It is still reasonable for `http.expose` to proxy requests into an
existing local HTTP server. But peer identity should be exposed in an
HTTP-native way, not by pretending a local server socket is the real
tailnet connection.

If the package later offers a higher-level `http.serve(...)` API, peer
identity should be a first-class request property rather than something
the user has to infer from a socket.

The main architectural benefits of this RFC land on raw stream and
datagram transports. HTTP benefits primarily from a cleaner API
boundary, not from a dramatic data-plane redesign.

As with Tailscale Serve, localhost-only backends should be the default
or strongly encouraged path for any identity-aware HTTP forwarding
story. Direct access to the backend port weakens the trust model for
forwarded identity data.

---

## Internal transport architecture

### Logical model

The internal Go↔Dart substrate should be treated as a real protocol.

Core needs:

- negotiate a transport version and optional capabilities at session
  startup
- open a logical stream with immutable metadata attached up front
- move bytes in both directions
- close one direction or both directions
- abort a stream explicitly
- apply backpressure

Illustrative frame/state kinds:

- `OPEN`
- `DATA`
- `CREDIT`
- `FIN`
- `RST`
- `GOAWAY`

This protocol is internal. It exists so the runtime boundary is
explicit and coherent.

The protocol design should treat stream lifecycle and session lifecycle
as separate concerns. In particular, `RST` and `GOAWAY` should not be
collapsed into a vague general-purpose “error frame.”

### Carrier

The protocol should run over a carrier that can vary by platform or
evolve over time.

Recommended default strategy:

- Unix domain sockets where supported by the target Dart SDK/toolchain
- loopback TCP fallback where UDS is unavailable or impractical

Current Dart documentation and changelog material around Windows Unix
domain socket support are still evolving. The architecture should not
assume a universal UDS matrix; carrier support must be verified against
the exact SDK/toolchain the package ships with.

Possible future research tracks:

- native-port / `Dart_PostCObject` backends
- direct socket handoff on platforms where it becomes viable

The important architectural point is:

> the protocol is the contract, not the carrier

### Authentication and security design

This RFC chooses the architectural direction, but it does not redefine
the transport-security details from scratch.

Unless deliberately replaced in a follow-up transport/security spec, the
security baseline from the earlier local-attestation design work should
be inherited conceptually:

- process-scoped secret established at startup
- derived subkeys for transport/domain separation
- integrity-protected metadata/control messages
- replay resistance
- fail-closed verification

What changes under this RFC is **where** that security machinery lives:
it moves from feature-specific bridge attestation into the unified
internal transport protocol.

The exact frame-level security design remains follow-up work and should
be specified explicitly before implementation begins.

Security/authentication is still required under this architecture.
Explicit native transport types solve the public API mismatch; they do
not remove the need for authenticated local handoff.

---

## Why this is better than the previous directions

### Better than per-connection attestation as the final architecture

Per-connection envelopes and signed headers are reasonable hardening
techniques, but they still preserve the assumption that the public API
should stay socket-shaped even when the underlying semantics are no
longer socket-shaped.

That solves a security symptom, but not the deeper API mismatch.

### Better than a large FFI-native pivot as the architecture itself

Moving everything to custom native-port channels might eventually be a
good backend implementation. But that is an implementation choice, not
the architecture.

This RFC intentionally separates:

- the public API model
- the internal transport protocol
- the carrier/backend

It also leaves room for non-canonical compatibility and interop lanes
without weakening the mainline design.

That keeps the architecture strong even if the implementation evolves.

---

## Implications for the roadmap

The existing roadmap principle:

> return standard `dart:io` types for network primitives

should be replaced with:

> return standard Dart types when semantics are faithfully preserved;
> use package-native transport types where the Dart↔Go runtime boundary
> materially changes transport semantics

This is the key contract change the rest of the roadmap should align to.

---

## Migration strategy

This change is cheaper now than it will be later because the raw
transport API is not fully settled on `main`.

### Existing API disposition

Existing socket-shaped raw transport APIs should be treated as
transitional, not as the long-term contract.

This RFC does not lock the exact release cadence for that transition,
but it does lock the direction:

- explicit Tailscale-native raw transport APIs become the canonical
  public surface before `1.0`
- any legacy `Socket` / `ServerSocket` / `RawDatagramSocket` shaped raw
  transport APIs, if kept temporarily, are migration aids only
- the project should not continue investing in socket-shaped raw
  transport APIs as the enduring design

Recommended sequence:

1. Freeze new raw transport API work until this direction is agreed.
2. Update the roadmap and status docs to reflect the new principle.
3. Introduce `TailscaleEndpoint`, `TailscaleIdentity`,
   `TailscaleConnection`, and `TailscaleListener`.
4. Design the internal stream protocol and carrier abstraction.
5. Implement `tcp.dial` and `tcp.bind` on the new substrate.
6. Decide whether `tls.bind` belongs in the first public transport
   slice or should wait until its semantics are fully nailed down.
7. Keep `http.expose` as an HTTP-native identity-forwarding layer.
8. Move `http.client` to the Go-backed HTTP lane.
9. Revisit future features such as Taildrop and Serve using the same
   explicit transport model rather than socket emulation.

This RFC intentionally stops at direction and migration shape. It does
not claim that the protocol design is complete.

Before implementation starts, the project still needs two dedicated
follow-up specs:

### Follow-up spec 1: Session transport and security

- handshake and startup
- version and capability negotiation
- authentication / integrity design
- carrier binding details
- session close semantics (`GOAWAY`)
- carrier-specific notes where they materially affect behavior

### Follow-up spec 2: Stream and datagram semantics

- `OPEN`
- `DATA`
- `CREDIT`
- `FIN`
- `RST`
- buffering and flow-control rules
- teardown ordering and lifecycle semantics
- datagram semantics for UDP-like transports

---

## Open questions

- Should the first carrier implementation be loopback TCP everywhere
  for simplicity, or UDS first on SDK/toolchain combinations where it
  is verified to work well?
- Should the package adopt `stream_channel` directly, or only borrow its
  conceptual model?
- Should the Go-backed HTTP lane support end-to-end cancellation for
  abortable requests from the first version, or defer that behavior?
- How much of the internal transport should be observable for debugging
  and operator tooling?

These are not minor polish questions. They are the main remaining design
questions below the architecture layer, and they should be resolved in a
follow-up implementation/specification round rather than improvised
during coding.
