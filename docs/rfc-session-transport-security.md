# RFC: Session Transport and Security for the Dart↔Go Runtime Boundary

**Status:** Draft  
**Priority:** Follow-up implementation spec  
**Scope:** Session handshake, authentication, integrity, versioning,
carrier binding, and session lifecycle for the internal Dart↔Go
transport  
**Builds on:** [`rfc-explicit-runtime-boundary.md`](./rfc-explicit-runtime-boundary.md)  
**Related docs:** [`api-roadmap.md`](./api-roadmap.md),
[`api-status.md`](./api-status.md),
[`rfc-stream-datagram-semantics.md`](./rfc-stream-datagram-semantics.md)

---

## Summary

This RFC specifies the **session-level** contract for the internal
transport between the Dart runtime and the embedded Go runtime.

It defines:

- how a session is created
- how the two runtimes authenticate each other
- how explicit key confirmation makes the session fully open
- how transport versions and capabilities are negotiated
- how carrier binding works
- how session integrity is enforced
- how the session shuts down (`GOAWAY`)

It does **not** define per-stream or per-datagram behavior in detail.
That belongs in the separate stream/datagram semantics spec.

The goal is to make the Dart↔Go runtime boundary:

- explicit
- authenticated
- versioned
- carrier-agnostic
- safe against spoofed local traffic in the stated threat model

---

## Relationship to the architecture RFC

The architecture RFC established the top-level direction:

- standard Dart types where semantics remain faithful
- package-native transport types for raw stream and datagram transports
- one explicit internal streaming substrate between Dart and Go

This document specifies the **session and security layer** of that
substrate.

It intentionally inherits the useful security baseline from the earlier
peer-attestation RFC:

- process-scoped secret established at startup
- hierarchical key derivation for domain separation
- replay resistance
- fail-closed verification

What changes is **where** that machinery lives: it now secures the
unified runtime transport instead of individual feature-specific bridge
mechanisms.

This document applies to the **canonical internal runtime session**
described by the architecture RFC. It does not define the behavior of
non-canonical escape hatches such as:

- compatibility proxy mode built around `tsnet.Loopback()`
- experimental native socket interop on platform-gated backends

---

## Goals

- Define one authenticated runtime session between Dart and Go.
- Prevent spoofed local peers from impersonating either side of the
  session.
- Bind session traffic to the correct process instance and session
  generation.
- Make session-open mean live peer participation, not just validated
  transcript shape.
- Support multiple carriers without changing the session contract.
- Support protocol version negotiation and optional feature negotiation.
- Make orderly session shutdown explicit.
- Be implementable on top of loopback TCP first, with other carriers
  later.

---

## Non-goals

- Defining `OPEN`, `DATA`, `FIN`, `RST`, `CREDIT`, or datagram payload
  behavior in detail.
- Defining public `TailscaleConnection` / `TailscaleWriter` lifecycle
  semantics beyond what is needed for session shutdown.
- Providing confidentiality stronger than same-process secret-based
  integrity in the stated threat model.
- Defining a public wire protocol.
- Committing to a specific carrier as part of the contract.

---

## Threat model

### In scope

- A co-resident local process can connect to locally bound transport
  carriers such as loopback TCP or Unix domain sockets.
- A co-resident local process can attempt to inject, replay, or reorder
  session frames.
- A co-resident local process can race a real runtime during startup or
  reconnect attempts.

### Out of scope

- Arbitrary code execution inside the Dart or Go runtime.
- Same-process memory inspection, debugger attachment, or secret
  extraction.
- Privileged kernel- or OS-level interception of process memory.
- Confidentiality against an attacker who can already read process
  memory.

Within this threat model, the session primarily needs:

- mutual authentication
- integrity
- replay resistance
- version/capability coherence

It does **not** require transport encryption distinct from the process
secret unless a later threat model expands.

---

## Design principles

### 1. The protocol is the contract, not the carrier

The session layer must behave the same regardless of whether the
carrier is:

- loopback TCP
- Unix domain sockets
- a future native-port transport

Carrier choice is an implementation detail below the session contract.

### 2. Session semantics are separate from stream semantics

This spec is about:

- who is connected
- what protocol version they agreed to
- what capabilities are enabled
- whether the session is healthy or closing

It is not about the lifecycle of individual logical streams.

### 3. Fail closed

Unknown version, bad MAC, invalid nonce, malformed handshake, or wrong
carrier/session binding must terminate the session immediately.

### 4. Keep the first version simple

The first session protocol should avoid speculative features such as:

- dynamic capability mutation after handshake
- rekeying mid-session
- multiple parallel authenticated sessions per runtime pair
- same-generation session re-establishment after fatal failure

Those can be added later if justified.

### 5. Borrow semantics from proven multiplexers

This session spec should not invent connection/session behavior from
scratch when stronger precedents already exist.

The intended semantic template is:

- QUIC-style separation of session lifecycle and stream lifecycle
- explicit graceful close vs reset
- negotiated startup
- stable identifiers and ordered frame sequencing

This spec borrows those ideas without inheriting transport features that
do not make sense for an in-process carrier, such as congestion control
or path migration.

---

## Session model

There is at most one active session between the Dart runtime and the Go
runtime for a given embedded Tailscale node instance inside one Dart
process.

The session is:

- long-lived
- authenticated
- versioned
- multiplex-capable

The two sides are:

- **Go side:** the embedded networking runtime
- **Dart side:** the host application runtime

The session carries:

- session control frames
- stream open/metadata frames
- stream data and lifecycle frames
- future datagram frames

The canonical session is therefore the transport authority for the raw
native transport APIs. Compatibility proxy mode is intentionally outside
this session model.

In v1, a session-fatal failure is also a **runtime-fatal failure for the
raw substrate**:

- there is no automatic session re-establishment within the same
  `Start()` generation
- recovery requires a fresh `Start()`
- a fresh `Start()` implies a new master secret and a new
  `sessionGenerationId`

This is intentionally strict. A same-process carrier disconnect or
session-fatal integrity error indicates runtime-level failure, not a
routine reconnect case.

### Session invariants

The session layer inherits the invariants in
[`runtime-transport-invariants.md`](./runtime-transport-invariants.md).
The most important ones at this layer are:

- carrier is not the contract
- session-fatal errors abort all streams
- session semantics are separate from stream semantics
- the runtime boundary is explicit and authenticated

---

## Secret lifecycle

### Master secret

- Go generates a fresh 32-byte random master secret on every successful
  runtime `Start()`.
- The secret is returned to Dart as part of the additive startup
  bootstrap contract.
- The secret is rotated on every new `Start()` cycle, including after
  `down()` or `logout()`.
- The secret is never persisted to disk.
- Dart clears the in-memory copy on `down()` on a best-effort basis.

This master secret scopes one **session generation**. Sessions from
different runtime starts must not authenticate each other.

### Session generation identifier

- Go generates a fresh 16-byte random `sessionGenerationId` on every
  successful runtime `Start()`.
- It is returned to Dart alongside the master secret.
- It is not negotiated during handshake.
- It is not derived from the master secret.

The `sessionGenerationId` exists to:

- bind the bootstrap contract to one runtime generation
- make same-generation and cross-generation behavior explicit in logs and
  diagnostics
- scope any optional replay-hardening or diagnostics that later versions
  may add

### Bootstrap contract at the control-plane boundary

The session bootstrap contract spans:

1. the additive `Start()` response from Go to Dart
2. the immediate carrier-attach control call that gives the attaching
   side the canonical carrier endpoint to connect to once the
   provisioning side has bound it

For v1, the bootstrap data is encoded in the existing structured control
response format used by startup. Fields should be represented as JSON
fields with binary values encoded as base64url **without padding**.

The required bootstrap fields are:

- `masterSecretB64`: 32 decoded bytes
- `sessionGenerationIdB64`: 16 decoded bytes
- `preferredCarrierKind`: one of `loopback_tcp`, `uds`, or future values

The bootstrap response must never be logged verbatim. It carries secret
material and should be treated as sensitive structured data.

For v1, one side provisions the canonical carrier endpoint and the other
side attaches to it. The protocol contract does not require which side
owns which step. The recommended first implementation is:

- Dart provisions the listener/bound endpoint
- Go attaches by dialing that endpoint

Once the provisioning side has successfully bound the concrete carrier
endpoint, it passes the canonical carrier binding details back to the
attaching side in a carrier-attach control call.

The required carrier-attach fields are:

- `carrierKind`
- `listenerOwner`: one of `dart`, `go`
- `host` and `port` for `loopback_tcp`
- `path` for `uds`

This split keeps the `Start()` response stable while still making the
carrier binding explicit and authenticated before the session opens.

If the provisioning side cannot bind the carrier endpoint, it must:

- surface a runtime error
- avoid sending `carrier-attach`
- fail the pending session bootstrap

The attaching side must validate `carrier-attach` against its own
pending session state and fail closed on mismatch.

For v1, if carrier-attach does not complete within **10 seconds** of
successful `Start()`, the pending session bootstrap fails and the
runtime must surface an error rather than waiting indefinitely.

### Key schedule

Do not use the master secret directly for handshake or frame MACs.

Use a small hierarchical HKDF-style key schedule:

1. per-`Start()` root secret
2. handshake key
3. transcript-bound session secret
4. directional traffic keys

Because the master secret is already a fresh 32-byte random value, v1
does not require an additional entropy-extraction phase beyond HKDF's
normal structure.

`sessionGenerationId` is a public HKDF salt by design. It scopes the
derivation context but does not require secrecy.

Required v1 derivation:

```text
handshake_key =
  HKDF-Extract(
    salt = sessionGenerationId,
    IKM = masterSecret)

session_secret =
  HKDF-Expand(
    PRK = handshake_key,
    info = "tailscale_dart:v1:session" || transcript_hash,
    L = 32)

dart_to_go_frame_key =
  HKDF-Expand(
    PRK = session_secret,
    info = "tailscale_dart:v1:dart_to_go_frame",
    L = 32)

go_to_dart_frame_key =
  HKDF-Expand(
    PRK = session_secret,
    info = "tailscale_dart:v1:go_to_dart_frame",
    L = 32)
```

This makes the post-handshake traffic keys:

- generation-scoped
- transcript-bound
- directional

which is a cleaner and more obviously correct v1 design than one
generation-wide frame MAC key.

---

## Carrier binding

The session must be bound to the actual carrier endpoint chosen at
startup.

### Required carrier binding inputs

Each side must know, or be able to validate:

- carrier kind (`loopback_tcp`, `uds`, future values)
- session generation identifier
- session endpoint details appropriate to the carrier

Examples:

- loopback TCP: listening host + listening port + listener owner
- UDS: socket path + listener owner

The precise binding fields are carrier-specific, but the handshake must
include a normalized carrier-binding description that is MAC-protected.

This prevents a session token or startup secret from being replayed
against a different carrier endpoint in the same process generation.

Carrier binding must be **minimal but real**. It should prevent
cross-carrier and cross-endpoint confusion without depending on
incidental transport details that make the protocol brittle.

For v1:

- `loopback_tcp` binds to listener owner, listening host, and listening
  port
- `uds` binds to listener owner and socket path

The protocol must not depend on ephemeral client-port details unless a
future carrier requires them for correctness.

---

## Version and capability negotiation

### Versioning

The session protocol is versioned from day one.

For v1:

- The initiator of `CLIENT_HELLO` advertises one or more supported
  protocol versions in priority order.
- The responder selects one supported version or rejects the handshake.
- If no common version exists, session establishment fails closed.

There is no implicit “best effort” fallback.

### Capabilities

Capabilities are negotiated once, during session establishment.

Capabilities are substrate-level only. They must not be used to leak
higher-level product features such as the Go-backed HTTP lane into the
session layer.

Examples of future substrate capabilities:

- stream transport enabled
- datagram transport enabled
- reason-code extensions enabled
- carrier-specific transport optimizations enabled

Capabilities are:

- immutable for the lifetime of the session
- advisory only within the negotiated version
- included in the MAC-protected handshake transcript

V1 negotiates an **empty capability set**. The field exists for forward
compatibility, not because v1 needs active capability switches.

No mid-session capability mutation exists in v1.

---

## Handshake

### Overview

The first session version uses a simple authenticated handshake:

1. transport connection established on the chosen carrier
2. Go sends `CLIENT_HELLO`
3. Dart validates it and replies with `SERVER_HELLO`
4. Go validates the transcript, derives directional traffic keys, and
   sends `SESSION_CONFIRM`
5. Dart validates `SESSION_CONFIRM`
6. session enters `open`

For v1:

- one side provisions the canonical carrier endpoint
- the other side attaches to that endpoint
- the listener side accepts the carrier connection unconditionally
- authentication is provided by the handshake MAC, transcript
  validation, and explicit initiator key confirmation

The recommended first implementation is still:

- Dart provisions the listener/bound endpoint
- Go dials the carrier

This is deliberate. A co-resident local process may succeed in
establishing the carrier connection, but it must not succeed in opening
an authenticated session without the bootstrap secret material.

V1 therefore guarantees **authenticity and integrity**, not strong local
availability. A co-resident process may still win the carrier connect
race and consume the pre-auth connection slot or timeout budget.

### Preconditions

Before `CLIENT_HELLO`:

- the carrier connection exists
- both sides know the current `sessionGenerationId`
- both sides have access to the session master secret for that
  generation
- no application streams exist yet

### Handshake messages

#### `CLIENT_HELLO`

Fields:

- `sessionProtocolVersions`: supported versions, highest preference
  first
- `clientNonce`: 16 random bytes
- `sessionGenerationId`: random value tied to the current runtime
  `Start()`
- `carrierBinding`
- `requestedCapabilities`
- `mac`

#### `SERVER_HELLO`

Fields:

- `selectedVersion`
- `serverNonce`: 16 random bytes
- `sessionGenerationId`
- `carrierBinding`
- `acceptedCapabilities`
- `mac`

#### `SESSION_CONFIRM`

After Go validates `SERVER_HELLO` and derives the transcript-bound
traffic keys, it sends a dedicated `SESSION_CONFIRM` session control
frame to Dart.

For v1:

- `SESSION_CONFIRM` is sent by the initiator of `CLIENT_HELLO`
- `SESSION_CONFIRM` carries no additional payload
- authenticity comes from the normal post-handshake frame MAC using the
  initiator→responder directional traffic key
- Dart must not mark the session fully `open` until `SESSION_CONFIRM`
  validates
- Go must not send stream/datagram/application frames before sending
  `SESSION_CONFIRM`

### Handshake MAC inputs

Handshake MACs must be deterministic and independent of JSON key
ordering or serializer behavior. This is the session layer's contract,
not an implementation detail.

Use canonical newline-delimited ASCII/UTF-8 `key=value` text with fixed
field order and no trailing newline.

Missing optional values are rendered as empty strings.

All base64-encoded binary values use base64url without padding.

#### `CLIENT_HELLO` canonical input

```text
msg=CLIENT_HELLO
session_protocol_versions=<comma-separated decimal versions>
client_nonce_b64=<base64url>
session_generation_id_b64=<base64url>
carrier_kind=<carrier kind>
listener_owner=<dart|go>
listener_endpoint=<canonical listener endpoint>
requested_capabilities=<comma-separated sorted capability names>
```

#### `SERVER_HELLO` canonical input

`SERVER_HELLO` MAC validation is transcript-shaped. Its canonical input
includes the validated `CLIENT_HELLO` fields plus the server response:

```text
msg=SERVER_HELLO
selected_version=<decimal version>
client_nonce_b64=<base64url>
server_nonce_b64=<base64url>
session_generation_id_b64=<base64url>
carrier_kind=<carrier kind>
listener_owner=<dart|go>
listener_endpoint=<canonical listener endpoint>
accepted_capabilities=<comma-separated sorted capability names>
```

This RFC freezes:

- fixed field order
- UTF-8 values
- empty string for missing optional values
- no trailing newline

`CLIENT_HELLO.mac` is:

```text
HMAC-SHA256(handshake_key, client_hello_canonical_bytes)
```

`SERVER_HELLO.mac` is:

```text
HMAC-SHA256(
  handshake_key,
  client_hello_canonical_bytes || 0x00 || server_hello_canonical_bytes)
```

After both messages validate, the transcript hash used for session key
derivation is:

```text
SHA-256(
  client_hello_canonical_bytes || 0x00 || server_hello_canonical_bytes)
```

This ensures that the final traffic keys are bound to:

- the exact negotiated version
- both nonces
- the exact carrier binding
- the exact accepted capability set
- the current session generation

### Handshake freshness, key confirmation, and handshake timeout

The load-bearing freshness guarantees in v1 are:

- fresh master secret per `Start()`
- `sessionGenerationId`
- fresh handshake nonces
- transcript-bound traffic keys
- explicit initiator key confirmation
- post-handshake directional sequence and MAC validation

Both sides must generate a fresh random 16-byte nonce for every
handshake attempt:

- Go generates `clientNonce`
- Dart generates `serverNonce`

This invariant is load-bearing. If either side were to reuse its
handshake nonce, transcript uniqueness would weaken and the later
sequence/MAC checks would be forced to carry more of the freshness
burden than intended.

`SESSION_CONFIRM` is the key-confirmation step that turns transcript
validation into a fully authenticated open session:

- Go proves it derived the initiator→responder traffic key by sending
  `SESSION_CONFIRM`
- Dart treats the session as still `handshaking` until that frame
  validates
- a replayed old `CLIENT_HELLO` may still cause local attach noise or
  timeout burn, but it must not be able to create a false-open session
  on Dart without live Go participation

For v1:

- handshake timeout is **5 seconds**
- timeout is measured from carrier connection establishment until the
  session enters `open`
- the protocol intentionally does **not** use wall-clock freshness
  fields such as `issuedAtMs`
- an explicit handshake-nonce replay cache is **optional hardening**, not
  a required correctness mechanism

This is a deliberate simplification for the current one-session-per-
generation model. If a later version adds session resumption, 0-RTT, or
same-generation re-establishment without a fresh `Start()`, explicit
replay-cache rules should be revisited.

### State machine

Session states:

- `idle`
- `carrier_connecting`
- `handshaking`
- `open`
- `closing`
- `closed`

Invalid state transitions fail closed.

No user-visible streams may be opened before the session enters `open`.
No post-handshake application frames may be sent before initiator key
confirmation is emitted and validated.

#### Allowed transitions

- `idle -> carrier_connecting`
- `carrier_connecting -> handshaking`
- `handshaking -> open`
- `handshaking -> closed`
- `open -> closing`
- `open -> closed`
- `closing -> closed`

No other transitions are valid in v1.

#### Transition triggers

- `idle -> carrier_connecting`
  - runtime decides to establish the canonical session
- `carrier_connecting -> handshaking`
  - carrier connection established
- `handshaking -> open`
  - full handshake completed, including initiator key confirmation
- `handshaking -> closed`
  - bad MAC, unsupported version, bad or missing session confirmation,
    timeout, or carrier failure
- `open -> closing`
  - local or remote `GOAWAY`
- `open -> closed`
  - session-fatal error
- `closing -> closed`
  - all streams drained and carrier closed, or drain timeout/failure

---

## Session frame integrity

After handshake, all frames carried on the canonical session must be
integrity-protected.

For v1:

- every frame carried on the canonical session, including future
  `DATA`/datagram-carrying frames, carries a frame header, payload, and
  MAC
- the first post-handshake control frame is `SESSION_CONFIRM` from the
  initiator to the responder
- MAC uses a **directional** session traffic key:
  - Dart→Go frames use `dart_to_go_frame_key`
  - Go→Dart frames use `go_to_dart_frame_key`
- MAC input must include:
  - protocol version
  - frame kind
  - monotonically increasing session sequence number
  - payload length
  - payload bytes

V1 deliberately MACs **every** frame rather than only control frames.
That keeps the integrity model simple and fail-closed. Future versions
may revisit this tradeoff only if profiling shows the session MAC to be
the dominant performance cost.

### Sequence numbers

The session uses a single monotonically increasing sequence number per
direction.

This is appropriate at the **session** layer even though per-stream
events are concurrent, because frames are serialized onto one carrier
connection in order.

Sequence numbers provide:

- replay detection
- truncation/order sanity
- one source of truth for per-direction integrity

For v1, session sequence numbers are fixed-width **64-bit** unsigned
integers with no wrap behavior.

A frame with:

- duplicate sequence number
- out-of-order sequence number
- invalid MAC

terminates the session immediately.

This is a session-fatal condition and therefore aborts all streams.

### Frame encoding

This RFC does not freeze every stream/datagram payload encoding, but it
does freeze the session-level integrity header layout.

All integer fields are encoded in **big-endian (network byte order)**.

For MAC purposes, the v1 frame header layout is:

```text
struct SessionMacHeaderV1 {
  uint8  protocol_version;
  uint8  frame_kind;
  uint16 reserved_zero;
  uint64 sequence_number;
  uint32 payload_length;
}
```

The frame MAC is:

```text
HMAC-SHA256(
  directional_frame_key,
  session_mac_header_bytes || payload_bytes)
```

This gives a fixed-layout MAC input and avoids ambiguity about field
order, widths, or endianness.

Required v1 properties:

- fixed-size frame kind and version fields
- explicit payload length
- explicit per-direction sequence number
- fixed-size 32-byte MAC
- maximum frame size limit

Recommended v1 maximum frame size:

- **64 KiB** total frame size before carrier write fragmentation

Actual stream backpressure and chunking rules belong to the stream
spec.

---

## `GOAWAY` and session shutdown

Session shutdown must be explicit.

### Graceful session close

Either side may send `GOAWAY` to indicate:

- no new streams may be opened
- existing streams may complete according to stream-level rules

After sending or receiving `GOAWAY`, the session enters `closing`.

While `closing`:

- new stream opens are rejected
- existing streams may continue according to stream-level semantics
- stream failures do not by themselves reopen the session

The stream/datagram semantics spec must define deterministic handling
for racing `OPEN` frames during `GOAWAY`, including a clear cutoff rule
for which initiator-owned identifiers may still be accepted.

### Abortive session termination

Any of these terminate the session immediately:

- bad frame MAC
- invalid sequence number
- malformed frame
- unsupported selected version
- handshake timeout
- session read/write I/O failure

In those cases:

- the session enters `closed`
- all live logical streams are failed
- no further frames are processed

There is no graceful recovery path in v1 from a session-fatal error.
Recovery requires a fresh runtime `Start()`.

### Session `done`

The public/internal notion of session completion should be protocol
semantic:

- a session is done when it is permanently closed, either gracefully or
  abortively

It must not be defined in terms of generic controller or sink behavior.

---

## Timeouts

Recommended v1 timeouts:

- handshake completion timeout: **5 seconds**
- `GOAWAY` drain timeout before forced close: **30 seconds**
- carrier-attach completion timeout: **10 seconds**

These values may be tuned later, but the protocol must define that they
exist and fail closed when exceeded.

All protocol timeouts in v1 must use a **monotonic clock source**, not a
wall clock.

---

## Logging and observability

Session failures should be logged with structured reasons such as:

- unsupported version
- bad handshake MAC
- bad or missing session confirmation
- handshake timeout
- bad frame MAC
- invalid sequence number
- malformed frame
- carrier binding mismatch
- session I/O failure

Do not log:

- master secret
- derived session secrets or traffic keys
- raw MAC values

This layer should also provide enough diagnostic surface for the public
runtime error stream to distinguish transport-auth failures from
ordinary stream-level closes.

The logging model should make it easy to answer:

- did the session fail before opening?
- did the session close gracefully via `GOAWAY`?
- did a session-fatal condition abort all streams?
- was the failure due to auth/integrity, key confirmation, carrier failure, or
  protocol misuse?

---

## Carrier guidance for v1

The first implementation should optimize for correctness and debuggable
behavior, not carrier cleverness.

Recommended order:

1. prototype on loopback TCP
2. validate handshake, sequencing, shutdown, and diagnostics
3. add UDS where verified on the actual supported SDK/toolchain matrix

This matches the architecture RFC’s rule that the carrier is an
implementation choice, not the session contract.

Experimental native-socket interop, where it becomes viable, should be
treated as a separate optimization path. It may reuse the session model
internally or bypass parts of it, but it must not become a requirement
for the canonical cross-platform contract.

---

## Non-goals for v1

- rekeying a live session
- resuming or re-establishing a session within the same `Start()`
  generation after carrier disconnect or fatal failure
- multiple concurrent sessions per embedded node
- per-frame confidentiality beyond HMAC-based integrity in the stated
  threat model
- making the session transport public API
- requiring an explicit handshake-nonce replay cache as part of the v1
  correctness contract

---

## Follow-on dependencies

This spec must be followed by the stream/datagram semantics spec, which
will define:

- `OPEN`
- `DATA`
- `CREDIT`
- `FIN`
- `RST`
- buffering and backpressure rules
- stream lifecycle semantics
- concrete UDP/datagram public shape

---

## Open questions

- Whether the carrier binding should be represented as canonical text in
  the handshake transcript or as a carrier-specific normalized binary
  blob.
- Whether carrier-specific peer-credential mechanisms (for example UDS
  peer credentials) should be additive checks or remain implementation
  optimizations only.
