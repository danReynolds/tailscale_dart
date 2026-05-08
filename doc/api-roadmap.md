# API roadmap

This package is consumer-first rather than full Tailscale CLI parity. The
current public spine is already useful for embedded Dart and Flutter apps:

- node lifecycle, auth, status, inventory, and pushed state streams
- outbound HTTP through `http.client`
- inbound HTTP with `http.bind`
- raw TCP, UDP, and TLS-terminated listeners
- Serve and Funnel forwarding for existing loopback HTTP servers
- node identity, diagnostics, prefs, and exit-node controls

Windows remains out of scope for this release. The POSIX data plane depends on
fd capabilities plus kqueue/epoll; Windows needs a separate backend decision.

## Remaining feature priorities

| Priority | Area | Why it matters | Current stance |
| --- | --- | --- | --- |
| P0 | Publishing readiness | Users need accurate README, changelog, platform metadata, package contents, and repeatable validation commands before public release. | Completed for the `0.3.x` public release line. |
| P1 | Windows backend decision | Windows is the only major platform gap. Supporting it likely requires either a Windows-native handle/reactor backend or a separate fallback carrier. | Deferred intentionally; do not expose as supported until designed. |
| P2 | Taildrop | Useful for app-to-app file transfer, but upstream semantics are user-device-oriented and the byte-path decision should stay stream-safe. | Declared API, not implemented. |
| P2 | Profiles | Useful when one app needs multiple tailnet identities, but most embedded apps only need one node identity. | Declared API, not implemented. |
| P2 | Tailscale Services | Useful for tagged service hosts and stable service names, but upstream `ListenService` is newer than the current `tailscale.com v1.92.2` pin. | Wait for a module bump, then design the Dart listener shape. |
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

Profiles are useful, but optional. They add account/state complexity without
improving the common "one embedded node per app install" path.

### Tailscale Services

Strongest use cases:

- expose a stable service name such as `svc:api` from one or more tagged Dart
  service nodes
- publish multi-port service hosts without coupling callers to individual device
  names

This should mirror upstream `tsnet.Server.ListenService` once the package bumps
past `tailscale.com v1.92.2`. Until then, keep it explicit as unsupported rather
than implying parity with the current upstream docs.

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
