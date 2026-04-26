# RFC: Shared POSIX FD Reactor

## Status

Draft proposal. Marked as a blocker for the 1.0 launch, not for the current
fd-backed transport PR merge.

## Summary

The current POSIX fd transport is correct but scales poorly: each adopted fd
starts one blocking reader isolate and one blocking writer isolate. That keeps
blocking syscalls off the main isolate, but it makes isolate count grow with
connection count.

Before 1.0, replace the per-fd isolate model with a shared POSIX fd reactor:

- one or a small fixed number of I/O isolates
- nonblocking fds
- platform polling through `kqueue` on Darwin and `epoll` on Linux/Android
- queued writes and read readiness dispatched back to Dart transport objects

The public API should not change. `TailscaleConnection`,
`TailscaleDatagramBinding`, and `TailscaleHttpRequest` remain package-native
transport objects. This is a backend scalability replacement.

## Problem

`PosixFdTransport.adopt(fd)` currently starts:

- one reader isolate blocked in `read(fd, ...)`
- one writer isolate performing blocking `write(fd, ...)`

That means:

- TCP connection: 2 isolates
- UDP binding: 2 isolates
- inbound HTTP request: 4 isolates, because request body and response body are
  separate fd transports

This is simple and has worked well for validation, but it does not support a
credible high-concurrency server story. A server handling 100 active inbound
HTTP requests could create roughly 400 transport isolates before counting accept
loops, worker isolates, or app isolates.

The issue is not fd handoff. The issue is using one blocking syscall isolate per
direction per fd.

## Goals

- Preserve the package-native public API.
- Keep fd-as-local-capability as the POSIX authority model.
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
- Keep Windows out of scope; Windows still needs a separate backend.

## Non-goals

- Exposing `dart:io.Socket` or `RawSocket`.
- Reintroducing the old authenticated session protocol on POSIX.
- Changing HTTP/TCP/UDP public API shapes.
- Making every transport knob public in v1.

## Proposed Design

Introduce an internal `PosixFdReactor` owned by the package runtime.

### Reactor Ownership

The reactor is lazily started on first fd adoption and lives for the process or
until the Tailscale runtime is disposed.

The reactor owns one or more I/O isolates. Each isolate owns:

- a native poller handle (`kqueue` or `epoll`)
- a registry from fd to transport id
- read interest
- write interest
- pending write queues
- close/shutdown commands

`PosixFdTransport.adopt(fd)` becomes registration with the reactor, not isolate
creation.

### Read Path

1. Dart transport registers fd for read interest.
2. Reactor marks fd nonblocking.
3. Poller reports read readiness.
4. Reactor drains up to `maxReadChunkSize`, packages bytes, and sends them to
   the owning transport.
5. If the Dart input subscription is paused, the transport removes read
   interest until resume.

This preserves the current pause-aware read contract without parking an isolate
in a blocking `read`.

### Write Path

1. `transport.write(bytes)` copies bytes immediately.
2. Transport enqueues the copied buffer with the reactor.
3. Reactor writes as much as the fd accepts.
4. Partial writes remain queued.
5. Poller write interest stays enabled while queued bytes remain.
6. The write future completes only after all bytes are written or fails on
   transport teardown/error.

This preserves copy-before-async-write and ordered delivery.

### Close Semantics

The reactor should retain the current shutdown rules:

- `closeWrite()` maps to `shutdown(fd, SHUT_WR)` after queued writes complete.
- `close()` / abort maps to `shutdown(fd, SHUT_RDWR)` then `close(fd)`.
- fd ownership closes exactly once.
- finalizers remain best-effort cleanup, not the primary lifecycle path.

### Platform Pollers

Darwin:

- use `kqueue`
- required for macOS and iOS

Linux / Android:

- use `epoll`
- Android should be tested on the same device/emulator path as current fd
  validation

Fallback:

- `poll` may be useful for tests or unusual POSIX platforms, but should not be
  the primary high-concurrency path.

## API Impact

No public API change is expected.

Potential internal configuration:

- reactor isolate count
- max read chunk size
- max pending write bytes per transport
- max total reactor pending bytes

These should remain internal defaults unless real users need tuning. Public
knobs can be added later without breaking API.

## Migration Plan

1. Add `PosixFdReactor` behind an internal interface.
2. Keep the current two-isolate `PosixFdTransport` as the reference backend
   while reactor tests are written.
3. Port existing fd transport tests to run against both implementations:
   - bidirectional bytes
   - copy-before-async-write
   - write ordering
   - half-close
   - full close
   - pending-write bounds
   - single-subscription input
   - pause-aware reads
   - large payload integrity
4. Add stress tests that would be pathological under per-fd isolates:
   - many concurrent TCP connections
   - many concurrent inbound HTTP requests
   - large response streaming with slow consumers
5. Switch POSIX fd adoption to the reactor backend.
6. Remove the per-fd reader/writer isolate implementation after parity.
7. Re-run macOS, iOS, Android, Linux, and Headscale validation.

## Acceptance Criteria

- Isolate count is bounded by configuration, not active fd count.
- Existing fd transport tests pass.
- Full root `dart test` passes.
- Go tests pass.
- Headscale E2E passes.
- macOS/iOS/Android demo probes pass.
- Linux real-tailnet validation passes.
- Stress test demonstrates hundreds of active fd transports without spawning
  hundreds of isolates.

## 1.0 Decision

Do not call the fd-backed transport production-ready for high-concurrency
server workloads until this proposal is implemented or explicitly replaced by
another bounded-I/O backend.

This is a 1.0 launch blocker because the public API invites inbound HTTP/TCP
server use. The current implementation is acceptable for the current PR and
validation demos, but the release should not imply production server scalability
while active fd count drives isolate count.
