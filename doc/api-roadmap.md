# API roadmap

The launch-critical architecture work is tracked in the
[accepted rearchitecture plan](rearchitecture-plan.md). Its runtime ownership,
auth conformance, encrypted StateStore, fail-safe teardown, publication
convergence, and platform-proof work takes priority over new feature breadth.
The plan now records R4d/R5 code that is present and the remaining target;
this roadmap continues to describe public API priorities.

This package is consumer-first rather than full Tailscale CLI parity. The
current public spine is already useful for embedded Dart and Flutter apps:

- node lifecycle, auth, status, inventory, and pushed state streams
- Keybay-backed encrypted persistence, explicit local forget, and Keybay-free
  ephemeral nodes
- outbound HTTP through `http.client`
- inbound HTTP with `http.bind`
- raw TCP, UDP, and TLS-terminated listeners
- Serve and Funnel forwarding for existing loopback HTTP servers
- node identity, diagnostics, prefs, and exit-node controls

Windows remains out of scope for this release. The POSIX data plane depends on
fd capabilities plus kqueue/epoll; Windows needs a separate backend decision.
Persistent support also follows Keybay's platform boundary: Android API 31+ and
Linux desktop with `secret-tool` plus an available, unlocked Secret Service.
Older Android and headless Linux use explicit ephemeral mode.

## Remaining feature priorities

| Priority | Area | Why it matters | Current stance |
| --- | --- | --- | --- |
| P0 | Runtime and lifecycle conformance | One `nodeRuntime`, non-destructive enrollment, and automatic fail-safe teardown are the ownership foundation for every public namespace. | R2-R5 and R7-R9 are complete. R8 retained the measured cache and moved it onto `nodeRuntime`; run the R10 physical gate before declaring the rearchitecture complete. |
| P0 | Encrypted node state | Persistent node identity must resist state-directory/backup copying without rebuilding platform custody already provided by Keybay. | R4d plus non-device R6 evidence are implemented: encrypted StateStore, direct Keybay custody, explicit reset, runtime-file classification, and first-party backup integration. Real-device custody/readback and mobile inventories remain release gates. |
| P0 | Serve/Funnel and mobile truth | Serve and Funnel share upstream state, while TLS certificate lookup is disabled on iOS/Android. | R5 implements one first-Up/config authority, ServeConfig Funnel, bounded ETag writes, and exact handles. Hosted tailnet/swap and macOS persisted process-crash/restart receipts passed 2026-08-10. Keep `tls.bind` explicitly unsupported in conformance with upstream and ServeConfig Funnel unqualified until separate device/sidecar receipts pass. |
| P0 | Publishing readiness | Users need accurate README, changelog, platform metadata, package contents, and repeatable validation commands before public release. | Historical `0.3.x` gate completed; R10 in the rearchitecture plan is the next launch gate. |
| P1 | Windows backend decision | Windows is the only major platform gap. Supporting it likely requires either a Windows-native handle/reactor backend or a separate fallback carrier. | Deferred intentionally; do not expose as supported until designed. |
| P2 | Taildrop | Useful for app-to-app file transfer, but upstream semantics are user-device-oriented and the byte-path decision should stay stream-safe. | Declared API, not implemented. |
| P2 | Profiles | Useful when one app needs multiple tailnet identities, but most embedded apps only need one node identity. | Declared API, not implemented. |
| P2 | Tailscale Services | Useful for tagged service hosts and stable service names; upstream `ListenService` is now available in the current `tailscale.com` pin. | Design the Dart listener shape before exposing it. |
| P3 | Generic LocalAPI escape hatch | Helps advanced users reach endpoints before a typed wrapper exists, but it can freeze an awkward low-level API if added too early. | Wait until the typed surface settles. |
| P3 | Advanced Serve/Funnel config | Raw config get/set, directory serving, richer policy inspection, and persistent background publications could be useful for operator tools. | Keep `forward/clear` small until real users need more. |

## Feature details

### Windows backend

The current fd backend is deliberately POSIX-only. A durable Windows design
should preserve the same public API while changing only the internal carrier.
Likely candidates are a Windows handle-based reactor, a named-pipe/socket
carrier, or a Windows-only authenticated session fallback. This should be a
design task before implementation; guessing here risks locking in a weak data
plane.

### Taildrop

Strongest use cases:

- send files from a mobile Flutter app to a desktop node without standing up an
  application-specific HTTP server
- receive files into an app-managed inbox where the app owns persistence,
  validation, and user approval

The API is already stream-shaped (`Stream<Uint8List>`) so callers can avoid
loading whole files into memory. The unresolved implementation choice is whether
to use fd-backed streaming, LocalAPI streaming, or a thin wrapper around
upstream Taildrop internals.

### Profiles

Strongest use cases:

- one app switches between a personal tailnet and a work tailnet
- development builds switch between staging and production tailnets without
  deleting local state

Profile switching is deliberately outside the current rearchitecture. A future
switch is a generation-changing teardown/start operation; it must never mutate
the identity of a live `nodeRuntime` in place.

Profiles are useful, but optional. They add account/state complexity without
improving the common "one embedded node per app install" path.

### Tailscale Services

Strongest use cases:

- expose a stable service name such as `svc:api` from one or more tagged Dart
  service nodes
- publish multi-port service hosts without coupling callers to individual device
  names

This should mirror upstream `tsnet.Server.ListenService`, which is available in
the current `tailscale.com` pin. Keep it explicit as unsupported until the Dart
listener shape is designed rather than implying parity with the current upstream
docs.

### Generic LocalAPI escape hatch

An escape hatch would let advanced callers issue LocalAPI requests directly.
That is powerful, but it also exposes upstream daemon internals and can become
hard to support once users depend on raw endpoint shapes. Prefer typed wrappers
for high-value APIs first; add the escape hatch last if real usage shows gaps.

### Advanced Serve/Funnel config

`serve.forward` and `funnel.forward` intentionally cover the common case:
publish an existing loopback HTTP server and return a closable process-scoped
handle. Future APIs could expose raw `ServeConfig`, directory serving,
persistent background publications, or more policy introspection, but those
should be demand-driven.

## Validation expectations

- Unit, local integration, and Go tests should run by default.
- Headscale E2E covers self-hosted control-plane behavior and POSIX fd data
  plane flows without a Tailscale account.
- Live Tailscale tests cover hosted-control-plane features that Headscale does
  not model: Funnel, hosted TLS certificates, and exit-node recommendation
  policy.
- Platform smoke validation remains required before claiming support for a new
  operating system.
