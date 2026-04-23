# API status

Current public surface of `package:tailscale`.

Legend:
- `✅ implemented` — callable today and covered by tests.
- `🧪 partial` — implemented enough to use, but still expected to evolve.
- `⏳ planned` — not implemented yet.

## Top level

| API | Status | Notes |
| --- | --- | --- |
| `Tailscale.init({stateDir, logLevel})` | ✅ implemented | One-time package configuration. |
| `Tailscale.instance` | ✅ implemented | Process-wide singleton. |
| `up({hostname, authKey, controlUrl})` | ✅ implemented | Starts the embedded node and bootstraps the authenticated runtime transport. |
| `down()` | ✅ implemented | Stops the node and preserves persisted credentials. |
| `logout()` | ✅ implemented | Stops the node and removes persisted credentials. |
| `status()` | ✅ implemented | Local node status snapshot. |
| `peers()` | ✅ implemented | Current peer inventory. |
| `listen(localPort, {tailnetPort})` | ✅ implemented | Exposes a local HTTP server to the tailnet. |
| `http` | ✅ implemented | Standard `http.Client`, backed by Go rather than a localhost proxy. |
| `tcp` | 🧪 partial | Raw stream namespace backed by the authenticated runtime substrate. |
| `udp` | 🧪 partial | Raw datagram namespace backed by the authenticated runtime substrate. |
| `onStateChange` | ✅ implemented | Broadcast lifecycle stream. |
| `onError` | ✅ implemented | Broadcast async runtime-error stream. |

## HTTP

| API | Status | Notes |
| --- | --- | --- |
| `tailscale.http.get/post/send/...` | ✅ implemented | Public surface is a normal `http.Client`. |
| Streaming request bodies | ✅ implemented | Real tailnet E2E coverage. |
| Redirect handling | ✅ implemented | Real tailnet E2E coverage. |
| Abortable requests | ✅ implemented | `AbortableRequest` is mapped through the Go-backed lane. |
| Inbound HTTP expose via `listen()` | ✅ implemented | Existing local-server forwarding path remains in place. |

## Raw TCP

| API | Status | Notes |
| --- | --- | --- |
| `tailscale.tcp.dial(host, port)` | ✅ implemented | Returns `TailscaleConnection`, not `dart:io Socket`. |
| `tailscale.tcp.bind(port)` | ✅ implemented | Returns `TailscaleListener`, not `ServerSocket`. |
| Immutable peer identity on accepted streams | ✅ implemented | Exposed as `connection.identity` when available. |
| Tailnet E2E coverage | ✅ implemented | Echo round-trip covered in Headscale E2E. |

## Raw UDP

| API | Status | Notes |
| --- | --- | --- |
| `tailscale.udp.bind(port)` | ✅ implemented | Returns `TailscaleDatagramPort`, not `RawDatagramSocket`. |
| Datagram identity attachment | ✅ implemented | Attached eagerly when available. |
| Bounded-drop receive semantics | ✅ implemented | Matches the RFC behavior. |
| Tailnet E2E coverage | ✅ implemented | Datagram round-trip covered in Headscale E2E. |

## Public transport types

| Type | Status | Notes |
| --- | --- | --- |
| `TailscaleConnection` | ✅ implemented | Logical stream with `input`, `output`, `close`, and `abort`. |
| `TailscaleListener` | ✅ implemented | Accept stream. |
| `TailscaleWriter` | ✅ implemented | Write-half abstraction with backpressure futures. |
| `TailscaleDatagramPort` | ✅ implemented | Datagram binding. |
| `TailscaleDatagram` | ✅ implemented | Immutable datagram delivery. |
| `TailscaleEndpoint` | ✅ implemented | Value type. |
| `TailscaleIdentity` | ✅ implemented | Immutable identity snapshot. |

## Not implemented yet

These areas are still planned rather than shipped:

- TLS-native listener APIs
- Funnel
- Taildrop
- Exit node APIs
- Profiles
- Prefs
- Diagnostics beyond current status/peer snapshots
- Public `whois`
- Serve/Funnel config APIs
