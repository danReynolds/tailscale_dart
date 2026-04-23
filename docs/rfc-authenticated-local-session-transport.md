# RFC: Authenticated Local Session Transport for `package:tailscale`

**Status:** Superseded by [`rfc-explicit-runtime-boundary.md`](./rfc-explicit-runtime-boundary.md)  
**Priority:** Historical alternative  
**Scope:** Internal transport between Dart and the embedded Go runtime  
**Related docs:** [`api-roadmap.md`](./api-roadmap.md), [`api-status.md`](./api-status.md)

---

## Summary

Adopt a single authenticated, multiplexed local session transport as the
core internal substrate between Dart and Go, and stop adding new
feature-specific localhost bridges.

The transport should:

- carry both control messages and byte streams
- attach trusted metadata to inbound accepted connections
- work on all supported platforms
- improve security over the current unauthenticated inbound loopback
  handoff
- reduce per-feature plumbing (`tcp.bind`, `tls.bind`, `http.expose`,
  eventually `http.client`, and future byte-stream features)

**Recommendation:**

- **Universal carrier:** loopback TCP
- **Protocol:** authenticated, multiplexed binary framing on top
- **Platform optimization:** Unix domain sockets on Linux, macOS, and
  Android under the same protocol
- **Research track:** direct accepted-socket handoff on strong Unix
  platforms only; not the mainline design

---

## Problem

Today, several features rely on ad hoc local bridges between the
embedded Go runtime and Dart:

- `tcp.bind`
- `tls.bind`
- `http.expose`
- `http.client` (different shape, but still a local proxy bridge)

The current inbound TCP/TLS pattern is:

1. Go accepts a real tailnet connection.
2. Go opens a local connection to a Dart-owned listener.
3. Dart receives that local connection as a normal `Socket`.

This loses the original peer boundary. A co-resident local process can
connect to the same local listener and inject data that looks like a
tailnet peer to Dart code. That is a real local spoofing vector.

This is not a problem with Tailscale TLS certificates, and not a
problem with Go-side TLS termination. It is a problem with the
unauthenticated local handoff layer.

More broadly, the current model duplicates transport logic across
features and keeps adding one-off local listeners, tokens, and proxy
paths.

---

## Goals

- Provide one internal transport primitive for all Dart↔Go traffic that
  needs more than simple request/response FFI.
- Eliminate unauthenticated inbound local handoff for stream-oriented
  features.
- Preserve or restore trusted peer metadata for inbound accepted
  connections.
- Keep the public Dart API mostly stable (`Socket`, `ServerSocket`,
  `RawDatagramSocket`, `http.Client`).
- Support all target platforms with one security model.
- Allow stronger per-platform carriers later without changing the
  higher-level protocol.

---

## Non-goals

- Replacing `tsnet` or forking Tailscale networking behavior.
- Requiring public API consumers to adopt custom socket types.
- Betting the package's architecture on undocumented or weakly
  documented OS-handle transfer behavior across every platform.
- Solving admin-plane APIs here.

---

## Constraints

### Dart platform primitives

Relevant Dart APIs:

- Loopback `ServerSocket.bind(...)` is available broadly and is the
  simplest universal local carrier.
- Unix domain sockets exist in `dart:io`, but are available only on
  Linux, macOS, and Android.
- `ResourceHandle` and `SocketControlMessage` exist and support passing
  OS resource handles via sockets.
- `Pipe` documentation explicitly discusses local IPC handle transfer on
  macOS and Linux, excluding Android.
- `HttpClient.connectionFactory` and `ConnectionTask.fromSocket(...)`
  provide a future path away from the current localhost HTTP proxy.

### Tailscale / tsnet primitives

Relevant upstream behavior:

- `tsnet` has the real peer context at accept time.
- `local.Client.WhoIs(remoteAddr)` is the upstream-supported identity
  lookup path for accepted peers.
- `libtailscale` exposes `listen`, `accept`, and `getremoteaddr`, which
  suggests direct accepted-socket preservation is viable in some
  environments.

---

## Alternatives considered

### 1. Keep the current per-feature localhost bridges

**Pros**

- Lowest short-term effort
- Minimal refactoring

**Cons**

- Leaves inbound spoofing risk in place
- Duplicates bridge logic across features
- Keeps per-feature proxy/listener setup
- Makes peer metadata inconsistent

**Decision:** reject

---

### 2. Replace everything with FFI function calls

**Pros**

- Good for control-plane operations
- Avoids a separate local transport for simple request/response calls

**Cons**

- Poor fit for long-lived bidirectional streams
- Awkward for async accept/read/write semantics
- Hard to map naturally onto `dart:io Socket` / `ServerSocket`
- Would still require a custom eventing / buffer / lifecycle system

**Decision:** use FFI for control operations only; reject FFI as the
stream transport substrate

---

### 3. Direct accepted-socket handoff into Dart everywhere

**Pros**

- Best security model
- Best performance model
- Preserves real remote peer semantics
- Avoids synthetic re-accept boundaries

**Cons**

- Cross-platform viability is not strong enough today
- Dart's documented handle-transfer story is strongest on Unix-like
  platforms, not clearly universal
- Higher implementation risk

**Decision:** keep as a research / optimization path, not the mainline
architecture

---

### 4. Unix domain sockets as the only carrier

**Pros**

- Better local isolation than loopback TCP
- Lower overhead on supported platforms

**Cons**

- Not universal: unavailable in Dart on Windows and iOS
- Does not by itself solve spoofing without authentication

**Decision:** use as an optimization where supported, not as the only
carrier

---

### 5. Authenticated multiplexed session protocol over one local stream

**Pros**

- Works on all platforms with loopback TCP
- One security model everywhere
- Solves the real problem: unauthenticated inbound local handoff
- Unifies TCP/TLS/HTTP-expose and later other stream features
- Leaves room for stronger carriers later

**Cons**

- More work than keeping today's bridges
- Not the absolute theoretical best performance on Unix

**Decision:** adopt

---

## Recommended architecture

### Core decision

Build one long-lived authenticated local session between Dart and the
embedded Go runtime.

On top of that session, run a small multiplexed binary protocol that
supports:

- opening logical streams
- sending byte frames
- closing streams
- reporting errors
- sending trusted metadata
- optional flow control

### Carrier strategy

- **Required everywhere:** loopback TCP
- **Optional optimization:** Unix domain sockets on Linux, macOS, and
  Android

The protocol above the carrier stays the same.

### Why this is the best universal design

- Loopback TCP is the only clearly universal local stream carrier in the
  current Dart platform story.
- Authentication and metadata restore trust; the carrier itself does not
  need to provide trust.
- UDS can improve security and performance on supported platforms later
  without changing the protocol or the public API.

---

## Platform matrix

| Platform | Recommended carrier | Security | Performance | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| All platforms | Authenticated protocol over loopback TCP | Good | Good | Low | Mainline |
| Linux | Same protocol over UDS | Better | Better | Medium | Later optimization |
| macOS | Same protocol over UDS | Better | Better | Medium | Later optimization |
| Android | Same protocol over UDS | Better | Better | Medium | Later optimization |
| Windows | Same protocol over loopback TCP | Good | Good | Low | Mainline |
| iOS | Same protocol over loopback TCP | Good | Good | Medium | Mainline until proven otherwise |
| Linux/macOS | Direct accepted-socket handoff | Best | Best | High | Experimental |
| Android | Direct accepted-socket handoff | Unclear | Unclear-to-best | High | Do not plan around |
| Windows | Direct accepted-socket handoff | Unclear | Unclear-to-best | Very high | Do not plan around |
| iOS | Direct accepted-socket handoff | Unclear | Unclear-to-best | Very high | Do not plan around |

---

## Security analysis

### Current inbound risk

Current inbound TCP/TLS/HTTP-expose bridges allow a co-resident local
process to connect to the Dart-side listener and impersonate an inbound
tailnet peer to application code.

That means:

- accepting an inbound `Socket` is not enough proof that the peer is a
  real tailnet node
- application-layer authorization can be bypassed if it assumes the
  inbound local hop is trusted

### Desired security properties

The new session transport must provide:

- Dart knows the data came from the embedded Go runtime, not an
  arbitrary local process
- Go knows it is talking to the owning Dart runtime, not an arbitrary
  local client
- every logical inbound stream has trusted metadata attached by Go
- frame boundaries and metadata are integrity-protected

### Confidentiality vs integrity

For local IPC, authentication and integrity matter more than transport
confidentiality.

If hostile same-user local code can already read process memory, local
channel encryption does not meaningfully improve the threat model.

So the protocol should prioritize:

1. strong session authentication
2. integrity protection on frames
3. optional encryption only if it materially simplifies key handling or
   implementation symmetry

---

## Performance analysis

Expected performance ranking:

1. direct accepted-socket handoff
2. authenticated session over UDS
3. authenticated session over loopback TCP
4. today's per-feature localhost bridges and proxies

The main gain comes from:

- replacing multiple local listeners/proxies with one long-lived session
- avoiding repeated local bind/listen/connect churn
- using binary framing instead of HTTP-over-local-HTTP for internal
  traffic

So even the universal loopback-TCP design should be a performance
improvement over the current architecture.

---

## Protocol sketch

The exact wire format can change, but the model should look like this.

### Session setup

At `up()` time:

1. Go creates a local listening endpoint.
2. Go generates a per-process session secret.
3. Dart connects to the local endpoint.
4. Dart and Go perform a small authenticated handshake using that
   secret.
5. Once authenticated, the session remains open for the process
   lifetime or until `down()` / `logout()`.

### Frames

At minimum:

- `open_stream`
- `data`
- `close_stream`
- `error`
- `metadata`
- `window_update` or equivalent backpressure support

### Stream metadata

Inbound accepted streams should carry trusted metadata such as:

- peer tailnet IP
- peer tailnet port
- stable node ID when available
- hostname when available
- additional transport-specific fields as needed

That metadata should be exposed to Dart without forcing application code
to trust `Socket.remoteAddress` from a synthetic local carrier.

---

## API implications

The public API should stay mostly stable.

### Inbound APIs

These should migrate first:

- `tcp.bind`
- `tls.bind`
- `http.expose`

They should gain trusted accepted-connection metadata exposed by the
library, rather than relying on `conn.remoteAddress` for tailnet
identity.

### Outbound APIs

`http.client` can stay on its current proxy path initially, but it
should eventually be able to move onto the same session transport using
structured request/response frames or a `connectionFactory`-based socket
path.

### UDP

UDP already has a different framing model and preserves peer datagram
addressing better than current inbound TCP/TLS bridges. It does not
need to be the first migration target.

---

## Migration plan

### Step 1: freeze new ad hoc local bridges

Do not add more feature-specific localhost bridge designs on top of the
current model.

### Step 2: implement the session transport skeleton

- loopback TCP carrier
- session auth
- framed multiplexing
- metadata support

### Step 3: migrate inbound TCP

Replace the current `tcp.bind` inbound handoff with session streams.

### Step 4: migrate inbound TLS

Keep Go-side TLS termination, but deliver accepted streams to Dart via
the authenticated session.

### Step 5: migrate HTTP expose

Move inbound HTTP forwarding onto the same substrate.

### Step 6: add UDS carrier optimization

Use UDS instead of loopback TCP on Linux/macOS/Android behind the same
session protocol.

### Step 7: evaluate `http.client`

Optionally replace the localhost HTTP proxy with session-based request /
response forwarding.

### Step 8: prototype direct accepted-socket handoff on Unix

Only after the mainline transport is stable.

---

## Consequences

### Positive

- one security model for local cross-runtime traffic
- fewer feature-specific bridges and listeners
- stronger inbound trust boundary
- cleaner path for future stream features
- better long-term fit for `http.expose`, Taildrop, and similar APIs

### Negative

- non-trivial implementation effort
- more internal protocol complexity than today's simple bridges
- short-term migration cost

---

## Open questions

- What exact metadata should be attached to inbound streams: just peer
  IP/port, or richer identity?
- Should integrity be done with a MAC-only design, or should the session
  be fully encrypted for symmetry even if confidentiality is not the
  main goal?
- What minimum flow-control model is sufficient for `Socket`-like
  semantics without overengineering?
- When `http.client` migrates, should it use structured HTTP frames or a
  direct socket-creation path via `HttpClient.connectionFactory`?

---

## Decision

The package should adopt a single authenticated, multiplexed local
session protocol as its core internal transport.

The universal baseline carrier is loopback TCP. Unix domain sockets are
an optimization where supported. Direct socket handoff remains a future
platform-specific optimization path, not the architectural baseline.
