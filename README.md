<p align="center">
  <img width="160" height="160" alt="tailscale.dart logo" src="https://github.com/user-attachments/assets/56a2a857-c5e7-42eb-9366-506daa56c5f9" />
</p>

# Dart 💙 Tailscale

[![pub package](https://img.shields.io/pub/v/tailscale.svg)](https://pub.dev/packages/tailscale)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/danReynolds/tailscale_dart/blob/main/LICENSE)
[![Dart 3.12+](https://img.shields.io/badge/Dart-3.12+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux-brightgreen.svg)](#platform-support)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-70ffb1.svg)](https://danreynolds.github.io/tailscale_dart/)
[![API reference](https://img.shields.io/badge/api-dartdoc-0175C2.svg)](https://danreynolds.github.io/tailscale_dart/api/)

Build Dart and Flutter apps that talk to each other directly — no public servers, no VPN setup, no NAT punching code — over an encrypted [Tailscale](https://tailscale.com) or [Headscale](https://github.com/juanfont/headscale) tailnet.

`package:tailscale` embeds upstream Go [`tsnet`](https://pkg.go.dev/tailscale.com/tsnet) and exposes typed Dart APIs for lifecycle, node identity, HTTP, TCP, UDP, TLS, Serve, Funnel, prefs, exit nodes, and diagnostics. Your app authenticates as its own node on the tailnet — users never install or configure a Tailscale client.

> **Status:** `0.9.0`, pre-1.0. The core API is stable enough to build on, but minor versions may include breaking changes until 1.0. Production users are welcome — please [open an issue](https://github.com/danReynolds/tailscale_dart/issues) or [start a discussion](https://github.com/danReynolds/tailscale_dart/discussions) if something blocks you.

## Documentation

The [**developer site**](https://danreynolds.github.io/tailscale_dart/) is the canonical place to browse the package — full guide, examples, architecture diagrams, and a runtime model walkthrough.

| Where | What |
| --- | --- |
| [Developer site](https://danreynolds.github.io/tailscale_dart/) | Guide, examples, architecture — start here for rich browsing |
| [API reference](https://danreynolds.github.io/tailscale_dart/api/) | Generated dartdoc for every public symbol |
| [pub.dev](https://pub.dev/packages/tailscale) | Install, versions |
| [CHANGELOG](https://github.com/danReynolds/tailscale_dart/blob/main/CHANGELOG.md) | Release notes and breaking changes |
| [`example/`](https://github.com/danReynolds/tailscale_dart/tree/main/example) | Runnable Dart snippets |
| [Rearchitecture plan](https://github.com/danReynolds/tailscale_dart/blob/main/doc/rearchitecture-plan.md) | Implementation status, remaining gates, historical work disposition, and acceptance criteria |
| [Runtime lifecycle ADR](https://github.com/danReynolds/tailscale_dart/blob/main/doc/adr-runtime-ownership-and-lifecycle.md) | Per-lifecycle ownership, enrollment semantics, and automatic fail-safe teardown |
| [Encrypted-state ADR](https://github.com/danReynolds/tailscale_dart/blob/main/doc/adr-encrypted-node-state.md) | Direct Keybay custody binding, encrypted StateStore, failure matrix, and no-migration reset policy |
| [`doc/`](https://github.com/danReynolds/tailscale_dart/tree/main/doc) | Status-labeled index of API docs, ADRs, RFCs, and current-architecture notes |
| [`test/README.md`](https://github.com/danReynolds/tailscale_dart/blob/main/test/README.md) | Test tiers, Headscale E2E, and live Tailscale suites |

> **Current qualification status.** The secure-state cutover, fail-safe
> lifecycle, runtime-owned Serve/Funnel convergence, and R7-R9 ownership,
> performance, and conformance work are complete. Hosted desktop Serve/Funnel
> and macOS production-Keybay process-crash/restart receipts passed on
> 2026-08-10. Physical iOS and Android custody, process-death recovery, reset,
> core data-plane, and profiling receipts passed on 2026-08-12/13. Mobile
> `tls.bind` remains unsupported upstream, and mobile HTTPS Serve/Funnel support
> remains explicitly qualified by the platform notes below.

## What you can build

- A **Flutter chat or collaboration app** where peers reach each other directly when possible — without you running relay or signaling infrastructure.
- A **headless Dart service** that joins ephemerally and exposes private HTTPS without opening any public port.
- An **on-device dashboard** that calls private internal APIs (Grafana, Home Assistant, internal admin) without a corporate VPN.
- A **shared Funnel endpoint** on desktop/server today — publish a local development server to the public internet, terminated with a real cert by Tailscale.
- Anything you'd reach for a [WireGuard](https://www.wireguard.com/) or [libp2p](https://libp2p.io/) library for, but you'd rather use Tailscale's identity, ACLs, and DERP fallback than build them yourself.

### When this is the right choice

- You want **app-level networking**, scoped to one process — not system-wide tunnels users have to consent to.
- You want familiar Dart shapes (`http.Client`, byte streams, datagrams) instead of `dart:io.Socket` wrappers around a localhost proxy.
- You're happy to delegate auth, WireGuard, ACLs, MagicDNS, DERP, HTTPS certs, Serve, and Funnel policy to upstream Tailscale.

### When to use something else

- **You need a system-wide VPN.** Use the official Tailscale apps; this package is per-process userspace networking.
- **Windows is a hard requirement today.** v1 is POSIX-only — see [Platform support](#platform-support).
- **You can't run a Go toolchain at build time.** This package compiles upstream tsnet on first build.

## Install

```yaml
dependencies:
  tailscale: ^0.9.0
```

The first `dart run`, `dart test`, or `flutter build` triggers a native build hook that compiles the Go runtime for the target platform. Subsequent builds are cached and only recompile when Go source changes.

Prerequisites:

- Dart SDK 3.12 or newer. Flutter apps need Flutter 3.44 or newer; use
  Flutter 3.44.6+ on Linux for its native-assets bundle fix.
- Go 1.26 or newer on `PATH` (or Go 1.25+ with the default
  `GOTOOLCHAIN=auto`, which auto-fetches the 1.26.5 toolchain that
  `tailscale.com` requires).
- Native toolchain for the target platform: Xcode for iOS/macOS, Android NDK through Flutter for Android, and a C toolchain for Linux.

## Quick start

```dart
import 'package:tailscale/tailscale.dart';

Future<void> main() async {
  Tailscale.init(
    stateDir: '/app/state',
    appId: 'com.example.myapp',
  );

  final tailscale = Tailscale.instance;
  final status = await tailscale.up(
    hostname: 'dart-node',
    authKey: 'tskey-auth-...',
  );

  print('node: ${status.stableNodeId}');
  print('ipv4: ${status.ipv4}');
}
```

`appId` is the embedding application's stable identifier (normally its
reverse-DNS bundle/application ID). Tailscale reserves `<appId>.tailscale` as a
dedicated Keybay namespace; keep the same `appId` and `stateDir` for the life
of the installation. `init` validates and freezes that binding but does not
access secure storage until a persistent runtime needs custody.

Embedded tsnet uploads diagnostic logs to Tailscale by default, including when
the node uses Headscale. This matches upstream Tailscale behavior and is
separate from local stderr verbosity. Pass `noLogsNoSupport: true` to `init`
to disable those uploads before the first runtime starts; doing so also opts
out of support that depends on the diagnostics. `TailscaleLogLevel.silent`
controls only local native stderr output.

Persistent `up()` may omit the auth key on a fresh installation; upstream then
returns `needsLogin` with an authorization URL for interactive enrollment.
Supplying a key is the non-interactive path. Subsequent launches can omit it
because the node identity is persisted in `stateDir`.

Persistent nodes use one authenticated encrypted Go StateStore at
`stateDir/tailscale/tailscaled.state.enc`. One random 32-byte data-encryption
key (DEK) is stored in the dedicated Keybay namespace and retained in memory
only for the runtime lifetime. Routine StateStore reads and writes do not call
Keybay. Missing or unavailable custody, malformed or tampered ciphertext,
unsafe permissions, and recognized pre-launch SQLite/FileStore layouts fail
closed; legacy identities are not migrated.

Only the logical Tailscale StateStore is encrypted by this mechanism. The
package-owned `tailscale/` subtree can also contain upstream logs, log
configuration, and TLS/certificate sidecars outside that encryption boundary.
The native runtime rejects symlinks and unexpected file types in that tree and
enforces current-user ownership with private directory/file modes before and
after startup. Keep the entire `stateDir` private and excluded from backups. On
Android, Keybay's separate `files/<appId>.tailscale/`
directory must also be excluded from cloud backup and device transfer. A Dart
package cannot rewrite its host application's backup manifest, so production
embedders own both exclusions; the persistent demo provides the integration
shape. Apple hosts use a fail-closed resource-value readback for the selected
state root while device-bound Keychain custody does not migrate.

Calling `logout()` is remote-first: confirmed control-plane success removes
the current logical profile, but the StateStore container and DEK remain.
`forgetLocalIdentity()` is the explicit local-only reset: it stops any active
runtime, records durable reset intent, deletes the exact DEK, and removes only
the package-owned `tailscale/` subtree. It does not contact the control plane,
so the remote node can remain until an administrator or expiry policy removes
it.

For short-lived CI jobs, preview environments, and disposable test nodes, pass
`ephemeral: true` to register a node that Tailscale removes after it goes
inactive:

```dart
await Tailscale.instance.up(
  hostname: 'preview-pr-842',
  authKey: 'tskey-auth-...',
  ephemeral: true,
);
```

Ephemeral startup requires a non-empty auth key. It uses an in-memory
StateStore and a fresh owner-only temporary runtime directory, removes that
scratch directory on normal close, and never reads, writes, or deletes Keybay.
It refuses to start if the configured persistent root contains recognized or
unexpected package state; choose an empty `stateDir` rather than expecting
ephemeral mode to reuse or clear a persistent identity.

### Persistent-storage platform requirements

- **iOS and macOS:** persistent nodes use Keybay's Keychain-backed custody.
- **Android:** persistent nodes require Android 12 / API 31 or newer. Older
  Android versions can use explicit ephemeral mode.
- **Linux desktop:** persistent nodes require `secret-tool` and an available,
  unlocked Secret Service collection. There is no supported Keybay custody
  contract for headless Linux sessions, so headless services must use explicit
  ephemeral mode.

Persistent startup fails closed when these custody requirements are not met;
there is no plaintext fallback.

## Feature support

Area | API | Status | Notes
--- | --- | --- | ---
Lifecycle | `init`, `up`, `down`, `logout`, `forgetLocalIdentity`, `status` | Supported | Persistent state uses one Keybay-custodied DEK and an encrypted Go StateStore. `up(ephemeral: true)` uses an in-memory store and no Keybay. `logout()` is remote-first and retains local storage; `forgetLocalIdentity()` is the explicit local-only destructive reset.
Reactive state | `onStateChange`, `onError`, `onNodeChanges` | Supported | Go pushes updates to Dart; callers do not poll.
Node identity | `nodes`, `nodeByIp`, `whois` | Supported | Use stable node IDs for durable references.
Outbound HTTP | `http.client` | Supported | A normal `package:http` client routed through tsnet.
Inbound HTTP | `http.bind` | Supported | Package-native request/response types backed by fd streams.
Raw TCP | `tcp.dial`, `tcp.bind` | Supported | Explicit read/write halves and half-close.
Raw UDP | `udp.bind` | Supported | Message-preserving datagrams with remote endpoint metadata.
TLS listener | `tls.bind` | Desktop/server only | Requires MagicDNS and HTTPS. Upstream's certificate endpoint is disabled on iOS/Android, so mobile termination is explicitly unsupported; the package does not add a parallel certificate path.
TLS discovery | `tls.domains` | Supported read-only API | Reads the runtime's advertised certificate domains directly; this does not provision a certificate or imply that `tls.bind` works on mobile.
Serve | `serve.forward`, `serve.clear` | Desktop/server qualified | Tailnet publication through the runtime-owned ServeConfig manager. The R5 replacement/exact-handle and macOS persisted process-crash/restart receipts passed 2026-08-10. The iOS receipt proved replacement boundaries but not a complete HTTPS lifecycle; Android hosted publication was not run.
Funnel | `funnel.forward`, `funnel.clear` | Desktop/server qualified | The public-visibility mode of the same ServeConfig mapping used by Serve. Public ingress, tailnet reach, and the R5 swap receipt passed on desktop/server. Physical iOS proved public Funnel ingress and Serve-to-Funnel replacement; Android hosted publication was not run.
Tailscale Services | N/A | Planned | Upstream `tsnet.Server.ListenService` is available in the current pin; no Dart wrapper yet.
Routing controls | `prefs`, `exitNode` | Supported | Subnet routes, Shields Up, tags, and exit nodes. Hostname is configured through `up()` so lifecycle state stays coherent.
Diagnostics | `diag` | Supported | Ping, metrics, DERP map, and advisory native-version checks. Embedded Tailscale is upgraded with the package or host application, not in place.
Windows | N/A | Unsupported | v1 is POSIX-only while the Windows data-plane backend is designed.

See [doc/api-status.md](https://github.com/danReynolds/tailscale_dart/blob/main/doc/api-status.md) for the full namespace-by-namespace API map.

## Examples

A few canonical snippets below. The [developer site](https://danreynolds.github.io/tailscale_dart/#examples) hosts the full set covering raw TCP/UDP, TLS termination, Funnel, exit nodes, and routing controls; runnable variants live in [`example/`](https://github.com/danReynolds/tailscale_dart/tree/main/example).

All snippets assume the node has been initialized and started:

```dart
Tailscale.init(
  stateDir: '/app/state',
  appId: 'com.example.myapp',
);
await Tailscale.instance.up(authKey: 'tskey-auth-...');
```

### Call a private HTTP service

`http.client` is a standard `package:http` client. Requests resolve MagicDNS and route through the embedded node.

```dart
final response = await Tailscale.instance.http.client.get(
  Uri.parse('http://api.tailnet.example.ts.net/health'),
);

if (response.statusCode != 200) {
  throw StateError('health check failed: ${response.statusCode}');
}
```

### Handle inbound HTTP directly

Use `http.bind` when the handler lives in this Dart process. No localhost proxy is opened.

```dart
final server = await Tailscale.instance.http.bind(port: 8080);

server.requests.listen((request) async {
  await request.respond(
    headers: {'content-type': 'text/plain; charset=utf-8'},
    body: 'hello from ${request.local.address}',
  );
});
```

### Use Shelf middleware directly

The tested adapter in [`example/shelf_adapter.dart`](https://github.com/danReynolds/tailscale_dart/blob/main/example/shelf_adapter.dart)
adds a `bindShelf` extension for apps that want Shelf middleware and routing.
Add `shelf` to your app and copy or import the adapter; `package:tailscale`
does not take Shelf as a core dependency.

```dart
import 'package:shelf/shelf.dart';
import 'package:tailscale/tailscale.dart';

import 'shelf_adapter.dart';

Future<void> main() async {
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler((Request request) {
        return Response.ok(
          'hello from Shelf over Tailscale',
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      });

  final server = await Tailscale.instance.http.bindShelf(
    port: 8080,
    handler: handler,
  );

  print('Shelf listening on ${server.tailnet}');
}
```

### Reuse an existing loopback server

Use `serve.forward` when your app already owns a local HTTP server and you want
to publish that existing loopback port.

The HTTPS example below is currently a desktop/server-qualified path. Mobile
HTTPS Serve and ServeConfig Funnel still need their own real-device and sidecar
receipts; `tls.bind` remains unsupported there with the upstream certificate
endpoint omitted.

```dart
final publication = await Tailscale.instance.serve.forward(
  tailnetPort: 443,
  localPort: 3000,
);

print('tailnet URL: ${publication.url}');
```

`serve.forward` traffic follows Tailscale Serve semantics, including Tailscale
identity headers for tailnet clients. `funnel.forward` changes the same
port/path publication to public Funnel visibility; it is not an independent
listener. The latest call at that coordinate owns the handler, and exact
publication handles cannot clear a replacement. Funnel traffic is public and
does not include Tailscale identity headers.

Funnel visibility is upstream host:port policy, not path policy. Enabling it on
port 443 can expose every ServeConfig path on that port. Use a dedicated public
port or authenticate all handlers that share it.

## Platform support

Platform | Status | Notes
--- | --- | ---
iOS | Core supported | Userspace tsnet, no VPN entitlement. Physical lifecycle, persistent custody/reconnect, reset, and private data-plane receipts passed. `tls.bind` is unsupported by the upstream mobile build; the hosted Serve/Funnel receipt is partial, so complete mobile HTTPS publication remains unqualified.
Android | Core supported | Userspace tsnet, no root. Persistent nodes require Android 12 / API 31+; older versions can run explicitly ephemeral nodes. Physical lifecycle, persistent custody/reconnect, reset, and private data-plane receipts passed. `tls.bind` is unsupported by the upstream mobile build; hosted Serve/Funnel was not run.
macOS | Supported | Native asset and kqueue reactor path validated locally.
Linux | Supported with storage qualification | Native asset and epoll reactor path validated in Headscale E2E. Persistent nodes require a desktop session with `secret-tool` and an available, unlocked Secret Service; headless Linux supports ephemeral nodes only.
Windows | Unsupported | Excluded from the package platform list until a Windows-native backend is designed.

The package is intentionally POSIX-first because owned transports use native descriptors plus a shared kqueue/epoll reactor. Windows needs a different transport backend rather than a thin port of the POSIX implementation.

## Runtime model

```
Dart app / lifecycle supervisor
  |
  | typed API calls and streams
  v
Replaceable FFI worker isolate
  |
  | token-tagged control ops + fd-backed data-plane handoff
  v
Go nodeRuntime generation
  |
  | WireGuard, ACLs, MagicDNS, DERP
  v
Tailnet peers
```

Control-plane calls go through a worker isolate so Dart's main isolate does not
block on native work. The caller isolate supervises that worker: every startup
has a token known before dispatch, timeout or worker death quarantines only that
generation, and replacement waits for native watcher/teardown joins. Runtime
events carry the generation token back through Dart ports so stale pushes are
dropped. Native `down`/`logout` receipts remain token-addressable until the
caller receives them, so worker death cannot erase a completed result. A
failed native cleanup is typed as `runtimeCleanupFailed` and blocks replacement
for the rest of the process rather than guessing that teardown succeeded.

Each runtime also owns one automatic, bounded first-`Up` bootstrap and one
serialized ServeConfig publication manager. Public `running` and data-plane
readiness are withheld until upstream's per-Server reset succeeds. A bootstrap
failure quarantines that exact generation; Serve/Funnel mutations use bounded
ETag retries and an indeterminate commit likewise closes the generation rather
than returning without a trustworthy handle.

Owned transports (`http.bind`, `tcp.bind`, `udp.bind`, `tls.bind`) use private fd-backed capabilities. That keeps listener ownership inside the package and avoids pretending that a localhost proxy is secure. Forwarding APIs (`serve.forward`, `funnel.forward`) intentionally use loopback because their purpose is to publish an existing local HTTP server the application already owns.

## Roadmap

The core private-tailnet package path is implemented. Before the next launch
claim, the accepted [rearchitecture plan](https://github.com/danReynolds/tailscale_dart/blob/main/doc/rearchitecture-plan.md) aligns
lifecycle ownership, auth semantics, Serve/Funnel behavior, encrypted node
state, and platform evidence with current upstream Tailscale. Feature work
outside that gate remains tracked in [the API roadmap](https://github.com/danReynolds/tailscale_dart/blob/main/doc/api-roadmap.md).

## Contributing

Issues, bug reports, and PRs are welcome.

- **Found a bug or have a feature request?** [Open an issue](https://github.com/danReynolds/tailscale_dart/issues).
- **Have a question or want to share what you're building?** [Start a discussion](https://github.com/danReynolds/tailscale_dart/discussions).
- **Want to send a PR?** Run `dart analyze`, `dart test --exclude-tags live-tailscale`, and `tool/test_pr_gate.sh` before pushing. The full test setup — including the Headscale E2E suite and opt-in live Tailscale runs — is documented in [test/README.md](https://github.com/danReynolds/tailscale_dart/blob/main/test/README.md).

If you're using `package:tailscale` in production, I'd love to hear about it — open a discussion and let me know.

## License

[MIT](https://github.com/danReynolds/tailscale_dart/blob/main/LICENSE)
