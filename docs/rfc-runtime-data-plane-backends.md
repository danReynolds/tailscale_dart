# RFC: Runtime Data Plane Backends

## Status

Draft decision RFC.

## Summary

The public transport architecture should not change.

Dart should expose package-native transport types with explicit endpoint,
identity, lifecycle, and datagram semantics. Outbound HTTP should remain a
standard `http.Client` backed by Go-owned HTTP execution; inbound HTTP should
accept package-native request/response objects.

The backend should change.

The raw data plane should be implemented by the smallest local authority
primitive that preserves the public semantics:

- use a private OS capability when the platform can hand one to Dart
- use an authenticated session only when the carrier is addressable or ambient
- keep the public API independent of that backend choice

For POSIX, the evidence now points to fd handoff as the preferred raw TCP/UDP
backend. The authenticated session backend should become a fallback or
platform-specific backend, not the universal foundation.

## Problem

`package:tailscale` embeds a Go `tsnet` node inside a Dart process.

Go owns:

- tailnet routing
- ACL enforcement
- peer identity
- network connection establishment

Dart owns:

- the application API
- user-facing stream/datagram objects
- cancellation and consumption behavior

The raw transport backend must transfer two things from Go to Dart:

- a data-plane capability for bytes or datagrams
- trusted metadata describing the endpoint and peer identity

Everything else is implementation machinery.

## Invariants

These should remain true regardless of backend:

- raw TCP and UDP use package-native types, not fake `dart:io` sockets
- endpoint metadata and identity are attached by the Go side, then exposed as
  immutable Dart values
- control operations use FFI request/response calls
- data-plane operations are asynchronous and resource-bounded
- graceful close, abort, EOF, reset, and datagram drop semantics stay as defined
  by the stream/datagram RFC
- HTTP remains a separate semantic lane, with fd-backed body streams

The backend exists to satisfy these invariants with the least machinery that is
correct for the platform.

## Decision Rule

Choose the backend by local authority primitive:

1. If the OS can give Dart a private data-plane capability, use that.
2. If the only practical data carrier is addressable by unrelated local
   processes, authenticate the carrier.
3. If neither is available, the raw transport feature is not supported on that
   platform until a backend is proven.

This rule is simpler than starting from "one backend everywhere." It asks what
local authority the platform actually provides.

## Capability Backend

A capability backend gives Dart an object that no unrelated local process can
guess or connect to.

On POSIX, that object is a file descriptor.

Possession of the fd is the authority to read, write, half-close, and close the
connection. The kernel owns isolation and lifetime. A co-resident process cannot
send bytes into the connection by racing a loopback port or guessing a carrier
address.

That removes the need for a local data-plane protocol with:

- handshake authentication
- transcript-bound traffic keys
- per-frame MACs
- sequence numbers
- replay logic
- stream multiplexing

Those controls are necessary for an untrusted local carrier. They are not
necessary when the carrier is already a private kernel capability.

## Authenticated Session Backend

An authenticated session backend is still valid when the data carrier is ambient
or addressable.

Loopback TCP is the obvious example. Any same-user local process can attempt to
connect, so the runtime must authenticate the peer and every frame. In that
world the session/security RFC remains the right design: fail closed, bind the
session to the handshake, derive directional keys, sequence frames, and define
stream/datagram semantics above the session.

The important correction is scope: the session backend is not the canonical
answer everywhere. It is the answer for carriers that are not private
capabilities.

## POSIX Backend

### Evidence

The fd-handoff investigation proved:

- Dart can read, write, and close a Go-handed-off socketpair fd
- Dart can read handed-off fds asynchronously from a background isolate
- Go can expose listener readiness and return accepted fds over plain FFI
- real Headscale-backed outbound TCP works over a handed-off fd
- real Headscale-backed inbound TCP works over accepted handed-off fds
- real Headscale-backed outbound UDP works over a datagram socketpair
- real Headscale-backed inbound UDP works with a small endpoint envelope
- Linux arm64 synthetic fd handoff works in Docker
- macOS, iOS, and Android manual demo probes pass across HTTP, TCP, and UDP

This is enough to treat POSIX fd handoff as the preferred raw TCP/UDP backend
for the current PR scope. Linux real-tailnet validation remains useful before a
broader release claim, but it is not a blocker for the macOS/iOS/Android path
validated so far.

### TCP

Outbound TCP:

1. Dart asks Go to dial.
2. Go dials with `tsnet.Server.Dial`.
3. Go creates a socketpair.
4. Go bridges the tailnet connection to one end.
5. Go returns the Dart end as an fd.

Inbound TCP:

1. Dart asks Go to listen.
2. Go creates the `tsnet` listener.
3. Go returns a listener id and canonical local endpoint.
4. Dart starts a dedicated accept isolate when the application listens for
   connections.
5. The accept isolate blocks in `acceptNext(listenerId)` and receives one Dart
   fd per accepted tailnet connection.

This avoids `SCM_RIGHTS`. In this same-process embedding, FFI can return the fd
integer directly.

### UDP

Connected UDP can use an `AF_UNIX/SOCK_DGRAM` socketpair. Datagram boundaries
are preserved.

Bound UDP needs metadata because each delivery can come from a different peer.
The backend therefore needs a small internal datagram envelope:

```text
remote endpoint
optional peer identity snapshot or identity handle
payload bytes
```

The spike used a minimal endpoint-length-prefixed envelope. Production should
choose the smallest envelope that preserves `TailscaleDatagram.remote` and
identity semantics.

### FD Wrapper

Dart does not expose public `Socket.fromFd` or `RawSocket.fromFd`, so POSIX
should use a package-owned fd wrapper.

Required behavior:

- async read loop, likely in a background isolate
- serialized writes
- bounded write queue
- EOF and error propagation
- graceful output close with `shutdown(fd, SHUT_WR)` where supported
- abort/full close with `shutdown(fd, SHUT_RDWR)` before `close(fd)`
- fd ownership closed exactly once
- blocking native accepts isolated away from the main Dart event loop

The Linux smoke check made the shutdown rule concrete: closing the fd from the
main isolate did not reliably unblock a background isolate blocked in `read`.
`shutdown(fd, SHUT_RDWR)` before `close(fd)` did.

## Windows

Windows remains undecided.

The POSIX fd model does not directly apply. Candidate approaches:

- keep the authenticated session backend over loopback TCP
- prove a Windows handle/socket duplication backend
- design a Windows-native carrier that preserves the same public semantics

The project can choose POSIX fd handoff before the Windows answer is final, as
long as split backends are accepted.

If one backend everywhere is a hard requirement, use the authenticated session
backend everywhere and accept the POSIX complexity cost.

## HTTP

HTTP should stay package-native instead of pretending to be `dart:io.Socket`
plumbing.

Outbound HTTP keeps the familiar `package:http.Client` surface while Go's
`tsnet.Server.HTTPClient()` owns redirects, pooling, chunking, TLS, and request
execution semantics. Request and response bodies cross the Dart/Go boundary over
private fd-backed streams.

Inbound HTTP exposes `TailscaleHttpServer.requests`. Go owns the tailnet
listener and HTTP parser, then hands each accepted request to Dart with private
fd-backed request-body and response-body streams. There is no caller-owned
`localPort` reverse proxy in v1.

## Decision

Adopt the capability-first backend strategy.

- Keep the public transport architecture.
- Use POSIX fd handoff for TCP, UDP, and HTTP body streams on validated POSIX
  targets.
- Keep the authenticated session backend as fallback and likely Windows path.
- Treat the session/security RFC as backend-specific, not universal.

## Consequences

The old authenticated-session transport PR should not merge as the final POSIX
raw transport backend.

Salvage from it:

- public transport API shapes
- stream/datagram semantics
- behavior tests that describe public contracts
- worker/control-plane restructuring that does not depend on the session data
  plane

Defer or split out:

- POSIX session runtime
- POSIX session conformance hardening
- session-specific stream multiplexer code

The architecture docs should be amended from "one authenticated runtime session"
to "one public transport model with backend-specific data-plane capabilities."

## Production Plan

1. [x] Build the production POSIX fd wrapper.
2. [x] Implement POSIX TCP dial/listen with fd handoff.
3. [x] Implement POSIX UDP dial/bind with the minimal metadata envelope.
4. [x] Port public behavior tests from the old session branch.
5. [ ] Run Linux real-tailnet HTTP/TCP/UDP E2E.
6. [x] Check Android and iOS feasibility.
7. [ ] Decide the Windows backend.
8. [x] Move HTTP request/response bodies onto fd-backed streams.

## Open Questions

- Should UDP identity be included in each datagram envelope, or should the
  envelope carry endpoint metadata and resolve identity through a cache? V1
  currently exposes remote endpoint metadata and leaves `identity` nullable.
- Is the Windows answer the current authenticated session backend, or a
  Windows-specific capability backend?
