# RFC: Local Peer Attestation for Inbound Bridges

**Status:** Superseded by [`rfc-explicit-runtime-boundary.md`](./rfc-explicit-runtime-boundary.md)  
**Priority:** Historical intermediate design  
**Scope:** Security and identity propagation for inbound `tcp.bind`,
`tls.bind`, and `http.expose`; outbound `http.client` cleanup  
**Supersedes:** [`rfc-authenticated-local-session-transport.md`](./rfc-authenticated-local-session-transport.md)  
**Related docs:** [`api-roadmap.md`](./api-roadmap.md),
[`api-status.md`](./api-status.md)

---

## Summary

Adopt a narrow hardening design for the local Go→Dart handoff instead
of a whole-library transport rewrite.

The design is:

- `tcp.bind` / `tls.bind`: prepend a per-connection authenticated
  attestation envelope before any user bytes cross the local bridge.
- `http.expose`: inject signed peer-attestation headers into the
  proxied HTTP request instead of using a raw stream prelude.
- `http.client`: remove the localhost HTTP proxy and build on
  `HttpClient.connectionFactory` + `tsnet.tcp.dial`.

This fixes the real security gap in the current architecture:
unauthenticated local handoff for inbound traffic. It also unlocks a
safe public `TailscalePeer` model without replacing `dart:io Socket`
with custom channel types or building a multiplexed session protocol.

---

## Problem

Today, inbound stream-style features use a local bridge:

1. Go accepts the real tailnet connection.
2. Go reconnects to a local Dart listener.
3. Dart receives a normal local `Socket`.

That local hop is currently unauthenticated. A co-resident local
process can connect to the same loopback listener and inject bytes that
look like a tailnet peer to Dart code.

There are two separate problems:

1. **Spoofable local handoff:** Dart cannot distinguish a real
   Go-originated bridge connection from an arbitrary local connection.
2. **Missing trusted peer metadata:** even when the bytes do come from
   Go, the original tailnet peer identity is lost at the Dart socket
   boundary.

This is not a Tailscale certificate problem and not a Go TLS
termination problem. It is a local attestation problem.

---

## Goals

- Authenticate every inbound Go→Dart bridge connection used by
  `tcp.bind` and `tls.bind`.
- Preserve trusted peer metadata across `tcp.bind`, `tls.bind`, and
  `http.expose`.
- Keep standard Dart network types (`Socket`, `ServerSocket`,
  `HttpClient`) as the public surface.
- Reuse one trust model across raw streams and HTTP without forcing the
  same wire format onto both.
- Fail closed on malformed or forged metadata.
- Avoid inventing a larger internal session transport unless a future
  feature actually needs it.

---

## Non-goals

- Replacing `dart:io Socket` with custom transport/channel types.
- Building a multiplexed Dart↔Go session transport.
- Relying on direct socket/FD handoff across all platforms.
- Providing confidentiality on the local bridge beyond what same-host
  process isolation already gives us.
- Solving every future transport feature in this RFC.

---

## Threat model

### In scope

- A co-resident local process can open loopback connections to ports
  bound by the Dart process.
- A co-resident local process can send arbitrary HTTP requests to a
  local server port exposed via `http.expose`.
- A co-resident local process can replay bytes or headers it observed
  from earlier bridge traffic only if it can see that traffic in the
  first place.
- A hostile local process may try cross-protocol confusion, for example
  replaying a `tcp.bind` attestation into `tls.bind`.

### Out of scope

- Arbitrary code execution in the Dart or Go process.
- Same-process memory inspection, debugger attachment, or secret
  extraction.
- Privileged local attackers who can intercept or modify process
  memory.
- OS- or kernel-level compromise.

Within that threat model, a per-process secret plus per-message
attestation is sufficient.

---

## Decision

### 1. `tcp.bind` / `tls.bind`: authenticated stream envelope

Every accepted tailnet connection forwarded from Go to Dart starts with
a versioned attestation envelope before any user payload bytes.

The envelope is package-specific. Do **not** use PROXY protocol v2.

Reasons:

- there is no third-party consumer to interoperate with
- it still needs custom fields and custom integrity protection
- it increases parser surface without reducing code meaningfully

### 2. `http.expose`: signed peer-attestation headers

`http.expose` forwards to an arbitrary existing local HTTP server.
Prepending raw bytes would corrupt HTTP semantics, so it must use
headers instead of a stream envelope.

The proxy strips all reserved `Tailscale-*` headers from the inbound
request before adding its own signed headers.

### 3. `http.client`: remove the localhost HTTP proxy

The current outbound HTTP proxy is not needed once `tcp.dial` exists.
Replace it with:

- `HttpClient.connectionFactory`
- `ConnectionTask.fromSocket(...)`
- `tsnet.tcp.dial(...)`
- `SecureSocket.secure(...)` for `https://`

This is a cleanup and security simplification, not part of the inbound
attestation mechanism.

---

## Public API shape

### New value type

Add a public immutable value type:

```dart
final class TailscalePeer {
  const TailscalePeer({
    required this.ip,
    required this.port,
    this.stableNodeId,
    this.hostName,
  });

  final InternetAddress ip;
  final int port;
  final String? stableNodeId;
  final String? hostName;
}
```

It must implement `==`, `hashCode`, and `toString`.

### TCP / TLS

Expose trusted peer metadata on accepted sockets via an extension:

```dart
extension TailscaleSocketPeer on Socket {
  TailscalePeer? get tailscalePeer;
}
```

For sockets not produced by `package:tailscale`, the getter returns
`null`.

### HTTP

Expose first-party verification helpers. At minimum:

- a helper for `dart:io HttpRequest`
- a helper or middleware for `package:shelf`

These helpers must:

- verify the signed headers
- return `TailscalePeer` on success
- reject malformed, missing, duplicate, stale, or forged headers

Applications must **not** trust `Tailscale-*` peer headers unless they
have been verified by these helpers.

---

## Secret lifecycle

- Go generates a fresh 32-byte random master secret on every successful
  `Start()`.
- The secret is returned to Dart as an additive field in the existing
  start response.
- The secret rotates on every `up()` cycle, including after `down()` or
  `logout()`.
- The secret is never persisted to disk.
- Dart clears the in-memory secret on `down()` on a best-effort basis.

### Subkeys

Do not use the master secret directly for all MACs. Derive transport
subkeys from it using HMAC-SHA256:

- `tailscale_dart:v1:tcp`
- `tailscale_dart:v1:tls`
- `tailscale_dart:v1:http`

This provides domain separation between transports without needing a
separate key exchange.

---

## Attestation fields

Every attestation, regardless of carrier, signs the same logical field
set:

| Field | Description |
| --- | --- |
| `version` | Attestation format version. Start at `1`. |
| `kind` | One of `tcp`, `tls`, `http`. |
| `listenerId` | Random bind-scoped identifier generated by Go when the listener/proxy is created. |
| `issuedAtMs` | Unix time in milliseconds when the attestation was created. |
| `nonce` | 16 random bytes, encoded as lowercase hex in HTTP. |
| `peerIp` | Tailnet peer IP as text. |
| `peerPort` | Tailnet peer port as decimal text or integer. |
| `stableNodeId` | Optional stable node ID. Empty if unavailable. |
| `hostName` | Optional hostname. Empty if unavailable. |
| `httpMethod` | HTTP only. Empty for stream transports. |
| `httpPathQuery` | HTTP only. Exact request path + query as forwarded. Empty for stream transports. |

### Replay resistance

Replay protection uses:

- fresh secret on every `Start()`
- `kind` binding
- `listenerId` binding
- `issuedAtMs`
- `nonce`

Go and Dart both maintain a bounded replay cache per transport and
listener for the attestation TTL window. Reuse of a nonce within the
same `(kind, listenerId)` scope is rejected.

For v1, the attestation TTL is **5 seconds**. Anything older fails
closed.

This is preferred over a monotonic sequence because accepts and
requests can complete concurrently and out of order.

### Versioning

The attestation format is versioned from day one.

- Unknown version: fail closed.
- Unsupported `kind`: fail closed.
- Unknown optional fields may be ignored only after a future version
  negotiation plan exists. For v1, parsers should treat extra payload
  members as invalid unless explicitly documented.

---

## Canonical MAC input

Use one transport-independent canonical input string for the MAC. Do
not MAC ad hoc JSON serialization.

The v1 canonical form is UTF-8 text with fixed field order and newline
delimiters:

```text
version=1
kind=<kind>
listener_id=<listenerId>
issued_at_ms=<issuedAtMs>
nonce=<nonce>
peer_ip=<peerIp>
peer_port=<peerPort>
stable_node_id=<stableNodeId>
host_name=<hostName>
http_method=<httpMethod>
http_path_query=<httpPathQuery>
```

Rules:

- field order is fixed exactly as above
- keys are ASCII lowercase
- values are UTF-8
- missing optional values serialize as empty strings
- `httpMethod` and `httpPathQuery` are empty strings for `tcp` and
  `tls`
- newline is `\n`
- no trailing newline after the final field

The MAC is:

```text
HMAC-SHA256(derived_subkey, canonical_input_bytes)
```

This keeps signing deterministic without requiring an RFC 8785 JSON
implementation on both sides.

---

## Stream envelope format (`tcp.bind`, `tls.bind`)

Use a compact binary envelope before user bytes:

```text
4 bytes  magic      = "TSPA"
1 byte   version    = 0x01
1 byte   kind       = 0x01 (tcp) | 0x02 (tls)
2 bytes  reserved   = 0x0000
4 bytes  payloadLen = big-endian uint32
N bytes  payload    = UTF-8 JSON object carrying the attestation fields
32 bytes mac        = HMAC-SHA256 over the canonical MAC input
```

Notes:

- JSON is used here only as the payload container because it is easy to
  log and extend. It is **not** the signed representation.
- The payload must contain exactly the v1 fields relevant to the
  transport.
- Maximum `payloadLen` is 4096 bytes. Larger payloads fail closed.
- Dart must read the full envelope within **5 seconds** before exposing
  the socket to user code.

### Verification flow

1. Read and validate the fixed header.
2. Read exactly `payloadLen` bytes and parse JSON.
3. Rebuild the canonical MAC input from the parsed fields.
4. Verify:
   - version
   - kind
   - listenerId
   - TTL
   - nonce not previously seen in replay cache
   - HMAC with constant-time comparison
5. Only after success:
   - attach `TailscalePeer`
   - expose the socket
   - begin forwarding user payload bytes

On failure, close the connection immediately.

---

## HTTP header format (`http.expose`)

Reserve the `Tailscale-*` namespace for package-generated identity and
attestation headers.

Before forwarding a request to the local server, the proxy strips all
incoming `Tailscale-*` headers and then injects:

- `Tailscale-Attest-Version`
- `Tailscale-Attest-Kind`
- `Tailscale-Attest-Listener-Id`
- `Tailscale-Attest-Issued-At-Ms`
- `Tailscale-Attest-Nonce`
- `Tailscale-Peer-Ip`
- `Tailscale-Peer-Port`
- `Tailscale-Peer-Stable-Node-Id` (optional)
- `Tailscale-Peer-Hostname` (optional)
- `Tailscale-Attest-Signature`

For v1, `Tailscale-Attest-Signature` is **base64url without padding**
of the 32-byte HMAC output.

The HTTP MAC input includes the request method and path/query so that
captured headers cannot be replayed onto a different request target
within the same local server.

### Verification flow

Helpers must:

1. Read the reserved headers.
2. Reject missing required headers.
3. Reject duplicate reserved headers.
4. Rebuild the canonical MAC input using:
   - attestation fields
   - request method
   - exact forwarded path + query
5. Verify TTL, nonce uniqueness, and HMAC.
6. Return `TailscalePeer` on success.

Unsigned or invalid requests are **unauthenticated**. Apps that make
authorization decisions based on tailnet identity must verify before
trusting the headers.

### Future Tailscale Serve alignment

If the package later wraps Tailscale Serve identity headers such as
`Tailscale-User-Login`, they should be additive:

- `Tailscale-Peer-*` remains the generic node-level metadata set
- `Tailscale-User-*` remains a higher-level Serve-specific identity set

Both can coexist, but they have different semantics and must not be
conflated.

---

## Failure behavior

There is no permissive mode in v1.

### Stream transports

On malformed envelope, timeout, bad MAC, replay, stale timestamp, wrong
listener, or wrong `kind`:

- close the local connection immediately
- emit a typed runtime error on `onError`
- log the reason at error level

### HTTP

For `http.expose`, the local proxy still forwards requests because it
cannot know whether the app intends to use peer identity for authz.
However:

- verification helpers must fail closed
- invalid attestation must be observable through logs and `onError`
- docs must state clearly that direct local requests are unauthenticated
  unless verified

Add a new runtime error code for these failures, for example:

- `TailscaleRuntimeErrorCode.authFailure`

This distinguishes spoofing/tampering from generic bridge failures.

---

## Logging and observability

Log verification failures with structured reasons:

- malformed envelope
- oversized envelope
- envelope read timeout
- bad MAC
- stale attestation
- replay detected
- wrong listener
- wrong transport kind
- duplicate reserved headers

Do not log the master secret, subkeys, or raw MAC values.

---

## Implementation plan

### 1. Shared primitives

- Add master secret to the start response.
- Add subkey derivation in Go and Dart.
- Add `TailscalePeer`.
- Add a shared attestation builder/verifier module in Go.
- Add a shared attestation verifier module in Dart.

### 2. TCP / TLS

- Prefix each local bridge connection with the stream envelope.
- Verify before exposing accepted sockets.
- Attach `tailscalePeer` metadata.
- Cover both `tcp.bind` and `tls.bind`.

### 3. HTTP expose

- Strip incoming `Tailscale-*` headers.
- Add signed `Tailscale-Attest-*` and `Tailscale-Peer-*` headers.
- Add verification helpers for `HttpRequest` and `shelf`.

### 4. HTTP client

- Replace the localhost proxy with `HttpClient.connectionFactory`.
- Use `tsnet.tcp.dial` for `http://`.
- Use `tsnet.tcp.dial` + `SecureSocket.secure` for `https://`.
- Force direct connections (`findProxy = "DIRECT"`).

---

## Test plan

### Unit tests

- canonical MAC input generation in Go and Dart matches byte-for-byte
- transport subkey derivation is stable and domain-separated
- stream envelope parsing rejects malformed, oversized, truncated, and
  wrong-version payloads
- HTTP verification rejects missing, duplicate, stale, replayed, and
  forged headers

### Integration tests

- `tcp.bind`: accepted socket gets `tailscalePeer`
- `tls.bind`: accepted socket gets `tailscalePeer`
- replayed envelope on the same listener is rejected
- attestation for `tcp` cannot be replayed to `tls`
- listener A attestation cannot be replayed to listener B

### HTTP tests

- direct local request without headers is unauthenticated
- forged headers are rejected
- valid signed headers produce the expected `TailscalePeer`
- WebSocket upgrade still preserves headers on the initial request

### HTTP client tests

- `http://` requests work through `connectionFactory`
- `https://` requests work through `connectionFactory`
- connection reuse/pooling works across multiple requests to the same
  tailnet peer

---

## Rejected alternatives

- **Multiplexed local session transport:** too much machinery for the
  actual problem we need to solve today.
- **Whole-library custom FFI/native channel types:** incompatible with
  the package's socket-first public design unless a future feature
  proves otherwise.
- **PROXY protocol v2 for stream attestation:** no interoperability win,
  still custom in practice, wider parser surface.
- **Do nothing:** leaves local spoofing unresolved and blocks a safe
  trusted-peer API.

---

## Open questions

- Whether the stream envelope payload should remain JSON in v1 or move
  to fully binary length-prefixed fields later. The signed form stays
  canonical text either way.
- Exact public names for HTTP verification helpers.
- Whether replay caches should be process-global per transport or
  listener-scoped only. v1 assumes listener-scoped caches keyed by
  `(kind, listenerId)`.
