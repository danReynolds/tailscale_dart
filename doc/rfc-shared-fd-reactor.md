# RFC: Shared POSIX FD Reactor

## Status

Accepted design for the POSIX data-plane backend.

This replaces the current per-fd reader/writer isolate model. It does not
change the public TCP, UDP, or HTTP APIs.

## Summary

The fd-backed architecture is the right local transport model for POSIX: the fd
is the local capability, and Dart owns package-native transport objects instead
of pretending they are `dart:io.Socket`s. The current implementation proves the
model, but each adopted fd starts one blocking reader isolate and one blocking
writer isolate. That makes resource use scale with active fd count.

Replace that with a shared fd reactor:

- one or a small fixed number of reactor isolates
- nonblocking fds
- `kqueue` on macOS/iOS
- `epoll` on Linux/Android
- explicit wake fd for commands from Dart into the blocked reactor
- bounded per-transport and global pending write queues
- read readiness delivered only when the Dart stream has demand

`poll()` is not the intended backend. It may remain useful as a test or fallback
implementation, but the product architecture should use the native readiness
API on each POSIX family.

## First-Principles Constraint

The library is not trying to become a public edge proxy or a replacement
Tailscale daemon. A typical target is a private tailnet with roughly tens to
hundreds of nodes and dozens of active TCP/HTTP/UDP flows. The data plane still
needs a disciplined resource model because active connections, not node count,
drive memory, fd, and isolate pressure.

The correct long-term shape is therefore:

- keep the public API small and package-native
- keep fd handoff as the local authority boundary
- avoid unbounded queues
- avoid per-connection isolates
- use the kernel readiness primitive designed for the platform
- measure reactor latency and throughput rather than assuming a single loop is
  always enough

This is not premature optimization. It removes a structural scaling cost from
the core transport backend while keeping the complexity private.

## Problem

`PosixFdTransport.adopt(fd)` currently starts:

- one isolate blocked in `read(fd, ...)`
- one isolate performing blocking `write(fd, ...)`

That means:

- TCP connection: 2 transport isolates
- UDP binding: 2 transport isolates
- inbound HTTP request: 4 transport isolates, because request body and response
  body are separate fd transports

A server with 100 active inbound HTTP requests can create roughly 400 transport
isolates before counting accept loops, worker isolates, app isolates, or Flutter
isolates. That is not a clean production resource model.

The issue is not fd handoff. The issue is using blocking syscalls by assigning
each fd direction its own isolate.

## Goals

- Preserve `TailscaleConnection`, `TailscaleDatagramBinding`, HTTP client, and
  HTTP server public APIs.
- Keep fd-as-local-capability as the POSIX security model.
- Bound isolate count independently of active fd count.
- Preserve current transport semantics:
  - ordered writes
  - copy-before-async-write buffer ownership
  - single-subscription input streams
  - pause-aware reads
  - bounded pending writes
  - write-half close
  - full close / abort
  - deterministic fd cleanup
- Support TCP, UDP, and HTTP body streams through the same primitive.
- Keep implementation complexity hidden behind `PosixFdTransport`.

## Non-Goals

- Exposing `dart:io.Socket`, `RawSocket`, or platform fd handles publicly.
- Reintroducing the old authenticated loopback session protocol on POSIX.
- Changing HTTP/TCP/UDP public API shapes.
- Solving Windows. Windows remains a separate backend decision.
- Making every reactor knob public. Defaults should be internal unless real
  users need tuning.

## External API Notes

This RFC is an internal backend change. Public callers should continue to see:

- TCP as `TailscaleConnection` with separate `input` and `output`
- UDP as message-preserving `TailscaleDatagramBinding`
- HTTP as package-native client/server helpers with fd-backed bodies

If this refactor requires a public API change, treat that as a design failure
unless there is a concrete correctness issue that cannot be solved internally.

## Architecture

### Process-Wide Reactor

Create a lazily started process-wide `PosixFdReactor`.

The reactor owns one or more I/O isolates. The expected default is one reactor
isolate because the package targets private-tailnet workloads, but this default
must be proven by stress tests. Sharding must be part of the internal design
from the start so the package can move to `N` reactors without changing public
APIs or transport semantics.

Shard count is selected once at reactor startup. The initial default should be
the internal constant `1`, with an internal test/debug override. Do not derive
the default automatically from CPU count until stress data shows that CPU-based
sharding improves real workloads without adding unnecessary contention.

Each reactor shard owns:

- one platform poller handle
- one wake handle
- a registry from fd to internal transport id
- read interest state
- write interest state
- per-transport pending write queues
- close and shutdown state

`PosixFdTransport.adopt(fd)` registers the fd with the reactor. It does not
spawn per-fd read/write workers.

Shard assignment should be deterministic and internal, for example by transport
id or fd hash. A transport is owned by exactly one shard for its full lifetime.
The close path must not require cross-shard coordination.

### Accept Loops

Inbound TCP and HTTP currently use blocking accept isolates. Listening and
accept readiness are also fd-readiness problems, so the long-term backend should
fold accept loops into the reactor where the native side can expose listener fds
or readiness fds.

If a platform or native tsnet call cannot expose accept readiness cleanly, a
blocking accept isolate per listener may remain as a deliberate exception, but
it must be documented as such and excluded from the "active data fd count"
resource model. Do not leave accept-loop ownership implicit.

### Platform Pollers

Apple platforms:

- use `kqueue`
- use `EVFILT_READ` and `EVFILT_WRITE`
- use `EV_ENABLE` / `EV_DISABLE` or delete/re-add to match demand
- treat `EV_EOF` and `EV_ERROR` as transport terminal signals after draining
  any readable bytes that the platform reports

Linux / Android:

- use `epoll_create1`
- register fds with `epoll_ctl`
- use level-triggered readiness by default
- use `EPOLLIN` only while the Dart stream has read demand
- use `EPOLLOUT` only while queued writes exist
- treat `EPOLLERR` / `EPOLLHUP` / `EPOLLRDHUP` as terminal after attempting
  any final readable drain

The first implementation should prefer level-triggered readiness. Edge-triggered
mode is not required for the expected workload and is easier to get wrong: it
requires draining until `EAGAIN` and maintaining a fair ready list to avoid
starvation. Level-triggered readiness plus explicit interest enable/disable is
the more obvious correctness choice here.

### Wake Handle

The reactor isolate blocks in `kevent()` or `epoll_wait()`. A Dart `SendPort`
message alone cannot wake it. Every command from the main isolate to the reactor
must also signal a wake handle registered in the poller.

Linux / Android:

- prefer `eventfd(EFD_NONBLOCK | EFD_CLOEXEC)`
- write `uint64_t(1)` to wake
- drain the counter when handling the wake event

Apple platforms:

- prefer `EVFILT_USER` with `NOTE_TRIGGER` if it works reliably through Dart FFI
  on macOS and iOS
- otherwise use a nonblocking `socketpair` or pipe as the wake handle
- for fd-backed wake handles, register the read end with `kqueue`, write a byte
  to wake, and drain the read end when handling the wake event

The wake path is part of correctness, not just latency. Without it, reactor
commands can wait indefinitely behind a blocking poll call.

### FD Mode

Every adopted fd must be switched to nonblocking mode before registration:

- use `fcntl(F_GETFL)`
- set `O_NONBLOCK` with `fcntl(F_SETFL)`
- preserve existing status flags

All syscall paths must handle:

- `EINTR`: retry the interrupted syscall
- `EAGAIN` / `EWOULDBLOCK`: treat as not-ready, not as fatal
- short reads and short writes
- zero-length reads as EOF for stream fds
- zero-length datagrams as valid UDP messages at the datagram layer

### Read Path

The current contract is demand-driven: when a Dart input subscription is paused
or the transport's inbound queue reaches its internal bound, the backend must
stop pulling bytes so data does not accumulate unboundedly in Dart.

The reactor should preserve that without forcing a poller modify for every
chunk:

1. The transport enables read interest when a Dart listener is active and not
   paused.
2. The reactor leaves read interest enabled while demand is sustained and the
   inbound queue is below its bound.
3. On readiness, the reactor performs bounded reads up to `maxReadChunkSize` per
   read and yields fairly across ready transports.
4. If the Dart subscription pauses or the inbound queue reaches its bound, the
   transport disables read interest.
5. Resume or queue drain re-enables read interest.
6. EOF or error terminates the input stream and removes read interest.

This avoids both per-fd blocking isolates and per-chunk `epoll_ctl` / `kevent`
churn on hot streaming paths. Fairness is required: one hot fd must not be able
to monopolize the reactor loop.

Fairness should be implemented with a per-loop work budget, not by blindly
processing events in poller-return order until empty. A reasonable rule is:
process at most one read chunk per ready transport per loop iteration, then
return to the ready set. If a transport remains readable, it can be serviced on
the next iteration. Writes should follow the same principle with a per-transport
bytes-per-loop budget when large queues are present.

For datagram bindings, each reactor read must preserve message boundaries. A
zero-length datagram is valid and must not close the binding.

### Write Path

The current write contract is also retained:

1. `transport.write(bytes)` copies bytes immediately.
2. The copied buffer is enqueued against the transport id.
3. The returned future completes only after all bytes are accepted by the fd
   backend, or fails if the transport closes/errors first.
4. Writes are delivered in call order.

The reactor should maintain:

- per-transport pending byte limit
- global reactor pending byte limit
- per-transport inbound queue limit
- FIFO write queue per transport
- `EPOLLOUT` / `EVFILT_WRITE` interest only while queued bytes exist

Partial writes stay at the head of the queue with an offset. `EAGAIN` disables
immediate progress and leaves write interest enabled. A write error fails the
active and queued writes for that transport and closes it.

### Write / Close State

Each transport should have an explicit internal write state:

```text
open
  -> closingWriteRequested
  -> writeClosed
  -> closed

open
  -> closed

closingWriteRequested
  -> closed
```

Rules:

- `closeWrite()` in `open` records `closingWriteRequested`.
- While `closingWriteRequested`, existing queued writes continue draining, but
  new writes fail.
- When the queue is empty, the reactor calls `shutdown(fd, SHUT_WR)` and enters
  `writeClosed`.
- `close()` / `abort()` from any state enters `closed`, fails pending writes,
  removes poller interest, shuts down read/write, and closes the fd.
- A transport-local write error enters `closed`.

This state machine is intentionally small because close-after-partial-write is
where fd transports commonly leak descriptors or complete futures incorrectly.

### Close Semantics

The reactor owns the fd after successful registration.

Required behavior:

- `closeWrite()` queues `shutdown(fd, SHUT_WR)` after all prior writes complete.
- `close()` / `abort()` performs `shutdown(fd, SHUT_RDWR)` then removes the fd
  from the poller and closes it.
- closing is idempotent
- pending writes fail deterministically on full close
- late poller events for a closed transport are ignored
- fd cleanup happens exactly once
- exceeding `maxRegisteredTransports` fails adoption before the fd is exposed to
  the public API; if the fd has already crossed into Dart ownership, it must be
  closed immediately

On Linux, explicitly remove the fd from the epoll interest list before close.
The epoll documentation notes that interest-list removal can be subtle when
duplicated fds share the same open file description; explicit delete-before-close
is the least surprising rule.

Finalizers may remain as best-effort cleanup, but they must not be the primary
transport lifecycle mechanism.

### Error Policy

Transport-local I/O errors terminate only that transport.

Reactor infrastructure errors are fatal to the reactor and must fail all
registered transports. Examples:

- poller creation fails
- wake handle creation fails
- unrecoverable `kevent()` / `epoll_wait()` error other than `EINTR`
- internal registry corruption

Errors should surface through the existing `TailscaleException` hierarchy at API
boundaries. Internal transport tests may assert lower-level `StateError`s where
the public wrapper is intentionally absent.

## Implementation Shape

Keep `PosixFdTransport` as the public internal facade used by TCP, UDP, and
HTTP code. Behind it, introduce:

```dart
abstract interface class PosixFdTransportBackend {
  Future<RegisteredFdTransport> adopt(
    int fd, {
    required int maxReadChunkSize,
    required int maxInboundQueuedBytes,
    required int maxPendingWriteBytes,
  });
}
```

The first production backend should be:

```text
PosixFdTransport
  -> SharedPosixFdReactor
       -> DarwinKqueuePoller
       -> LinuxEpollPoller
       -> WakeHandle
```

The existing two-isolate implementation can remain temporarily as a reference
backend while parity tests are being written. It should be removed once the
reactor backend passes parity, stress, and platform validation.

Adoption should be synchronous if registration can be completed synchronously.
The current async adoption shape exists because the old backend waits for
isolate startup. The reactor should not preserve async adoption unless startup,
registration, or platform probing truly requires it.

### FFI Binding Strategy

Implement the native pollers with Dart FFI against libc/system symbols unless
that proves brittle during platform validation.

Required bindings include:

- common: `fcntl`, `read`, `write`, `close`, `shutdown`, `socketpair` or `pipe`
- Darwin: `kqueue`, `kevent`
- Linux/Android: `epoll_create1`, `epoll_ctl`, `epoll_wait`, `eventfd`

Because kqueue and epoll structs are platform-specific, add startup probes that
exercise:

- poller creation
- wake handle registration
- one wake event
- socketpair registration
- read readiness
- write readiness
- cleanup

If Dart FFI struct layout becomes fragile on any supported platform, add a tiny
native shim that exposes a stable package-owned event struct to Dart. Do not
move transport semantics into Go; the reactor remains Dart-owned infrastructure.
If a shim is needed, it should ship inside the existing package native asset
bundle so users still see one dependency and no separate C build step.

## Resource Bounds

The reactor must enforce at least these internal bounds:

- max read chunk size per read
- max inbound queued bytes per transport
- max pending write bytes per transport
- max total pending write bytes across the reactor
- max registered transports per reactor
- max events returned per poll loop

These bounds keep failure modes explicit if callers exceed the package's
intended operating envelope.

These should begin as internal constants/configuration. Public tuning can be
added later if real applications need it.

## Internal Observability

The reactor is load-bearing infrastructure, so it must expose private counters
and gauges for tests and future diagnostics.

Required metrics:

- reactor shard count
- registered transport count per shard and total
- queued inbound bytes per transport and total
- queued outbound bytes per transport and total
- poll wait duration
- poll loop iteration duration
- event batch size
- wake count
- read/write syscall counts
- `EINTR`, `EAGAIN` / `EWOULDBLOCK`, and hard syscall error counts
- close count by reason
- max observed event-loop tick latency

These metrics do not need to be public API. They should be queryable from tests
and available to package diagnostics later.

## Testing Plan

### Parity Tests

Run existing fd transport tests against both the old backend and the reactor
backend until the old backend is removed:

- bidirectional bytes
- copy-before-async-write
- write ordering
- half-close
- full close
- close idempotency
- post-close write rejection
- pending-write bounds
- single-subscription input
- pause-aware reads
- large payload integrity

### Reactor-Specific Tests

Add tests for:

- startup probe failure surfaces clearly
- `EINTR` retry where injectable
- `EAGAIN` / `EWOULDBLOCK` handling
- partial writes
- wake handle wakes a blocked reactor
- paused input disables read interest
- resumed input re-enables read interest
- close while write is pending
- `closeWrite()` after a partial write drains queued bytes before `SHUT_WR`
- late events after close are ignored
- max registered transport overflow closes/refuses the fd deterministically
- global pending byte bound
- many registered idle transports

### Integration And Stress Tests

Run stress tests that are intentionally bad for the old model:

- 100, 250, and 500 concurrent socketpair transports
- read throughput under sustained streaming
- write latency under backpressure
- reactor poll-loop and event-loop tick latency under load
- many concurrent TCP dials over Headscale
- many concurrent inbound HTTP requests
- large HTTP response streaming to slow consumers
- UDP burst/drop behavior

### Platform Validation

Required validation before treating the reactor backend as production:

- macOS local fd integration tests
- iOS simulator/device smoke matrix
- Android emulator/device smoke matrix
- Linux fd integration tests
- Linux real-tailnet validation
- Headscale E2E

## Migration Plan

1. Add the backend interface behind `PosixFdTransport`.
2. Keep the current per-fd isolate backend as the reference backend.
3. Add the shared reactor with platform poller abstractions.
4. Implement `DarwinKqueuePoller`.
5. Implement `LinuxEpollPoller`.
6. Add startup probes for both.
7. Run parity tests against both backends.
8. Add reactor-specific tests.
9. Add stress tests.
10. Run full platform validation with the reactor enabled behind an internal
    switch.
11. Switch default POSIX fd adoption to the reactor backend per platform after
    validation passes on that platform.
12. Remove the per-fd reader/writer isolate backend after all supported POSIX
    platforms pass.

## Acceptance Criteria

- Active fd count no longer drives isolate count.
- The normal runtime uses a fixed reactor shard count that does not scale with
  active fd count.
- Existing fd transport tests pass.
- Reactor-specific tests pass.
- Full root `dart test` passes.
- Go tests pass.
- Headscale E2E passes.
- macOS/iOS/Android smoke matrix passes.
- Linux real-tailnet validation passes.
- Stress tests demonstrate hundreds of active fd transports without spawning
  hundreds of isolates.
- Stress tests report acceptable read throughput, write latency under
  backpressure, and reactor event-loop tick latency.
- Internal reactor counters are available to tests.
- No public API changes are required.

## Decision

Implement the shared reactor using native readiness APIs:

- `kqueue` for macOS and iOS
- `epoll` for Linux and Android

Do not ship the per-fd isolate backend as the long-term transport backend. It is
acceptable as a reference implementation during the refactor, but the stable
architecture is fd capability transport plus a shared native reactor.

## References

- Linux `epoll(7)`: [man7.org/linux/man-pages/man7/epoll.7.html](https://man7.org/linux/man-pages/man7/epoll.7.html)
- Linux `eventfd(2)`: [man7.org/linux/man-pages/man2/eventfd.2.html](https://man7.org/linux/man-pages/man2/eventfd.2.html)
- Apple `kevent(2)` manual page: [developer.apple.com/.../kevent.2.html](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kevent.2.html)
- Python selector abstraction: [docs.python.org/3/library/selectors.html](https://docs.python.org/3/library/selectors.html)
- libuv event loop design: [docs.libuv.org/en/stable/design.html](https://docs.libuv.org/en/stable/design.html)
