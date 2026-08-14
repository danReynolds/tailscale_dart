# API status & usage

Reference for the public API surface of `package:tailscale`, grouped by
namespace. For each namespace: a description, current support status,
purpose, and a copy-pasteable
example. For the forward-looking phase plan, see
[`api-roadmap.md`](api-roadmap.md).

> **Architecture transition:** this file describes callable APIs in the current
> source. R4d's persistent StateStore is one authenticated encrypted Go
> envelope whose 32-byte DEK is held by Keybay; ephemeral nodes use an
> in-memory StateStore and no Keybay. R5's automatic first-`Up` gate and
> runtime-owned ServeConfig manager are also present. The [rearchitecture
> plan](rearchitecture-plan.md) and its
> [runtime](adr-runtime-ownership-and-lifecycle.md) and
> [encrypted-state](adr-encrypted-node-state.md) ADRs also describe later work
> and release evidence that has not all shipped. Encryption covers logical
> StateStore data, not every upstream log, config, or TLS sidecar in the package
> subtree.

The **core mobile public path** is lifecycle + private HTTP/TCP/UDP, identity,
diagnostics, prefs, and exit-node controls. Platform-qualified TLS and
Serve/Funnel forwarding remain useful desktop/server surfaces. Unimplemented
ideas are tracked separately in `api-roadmap.md`, not exported as placeholders.

**Legend:**
- ✅ Working — callable today, tested, returns real values.

**Convention:** all examples assume `final tsnet = Tailscale.instance;`
and that [`Tailscale.init`](#lifecycle-top-level) has already been called.

**Platform contract:** v1 is POSIX-only: Android, iOS, Linux, and macOS. The
fd-backed data plane depends on native descriptors plus kqueue/epoll. Windows
is intentionally unsupported until a Windows-native backend or fallback carrier
is designed.

Persistent-node custody follows Keybay's narrower platform contract. Android
requires Android 12 / API 31+. Linux requires desktop `secret-tool` plus an
available, unlocked Secret Service; headless Linux has no supported persistent
custody path. Older Android and headless Linux can use explicit ephemeral mode,
which never accesses Keybay.

**Implementation model:** this package aligns to both upstream
`tsnet.Server` and upstream `local.Client`. HTTP, TCP, UDP, and raw listeners
use `tsnet`; implemented node introspection, diagnostics, prefs, Serve/Funnel
configuration, exit-node controls, and certificate lookup use LocalAPI via the
runtime's cached `local.Client`. Profiles and Taildrop remain roadmap topics and
are not exported until implemented.

**Mobile publication qualification:** the current upstream v1.102.2 pin
compiles the LocalAPI certificate endpoint used by TLS termination as a 404
stub on iOS and Android, so `tls.bind` rejects immediately on those platforms;
the package does not add a parallel certificate path. R5 no longer uses
`ListenFunnel`; Funnel is ServeConfig visibility on the
shared handler. That path and HTTPS Serve remain unqualified on mobile until
real-device handshakes and persistent-sidecar inventory pass. The private
HTTP/TCP/UDP core remains the mobile support target.

**Version note:** the current repo pin is `tailscale.com v1.102.2`. Keep
upstream version skew visible when adding new wrappers.

## Namespace overview

| Namespace               | Feature                                                           | Track     | Status           |
| ----------------------- | ----------------------------------------------------------------- | --------- | ---------------- |
| [Lifecycle](#lifecycle-top-level) | Engine start/stop + node state snapshot + reactive streams | Core      | ✅        |
| [`http`](#http)         | Outbound HTTP client + inbound request server                     | Core      | ✅        |
| [`tcp`](#tcp)           | Raw TCP between tailnet nodes                                      | Core      | ✅        |
| [`tls`](#tls)           | Certificate-domain discovery and TLS-terminated listener           | Advanced  | domains ✅; bind ✅ desktop/server, unsupported mobile |
| [`udp`](#udp)           | UDP datagram bindings on a tailnet IP                               | Advanced  | ✅        |
| [`funnel`](#funnel)     | Public-internet HTTPS forwarding via Tailscale Funnel              | Optional  | ✅ desktop/server; mobile unqualified |
| [`serve`](#serve)       | Tailnet publication for existing local HTTP services                | Optional  | ✅ desktop/server HTTPS; mobile HTTPS unqualified |
| [`services`](#tailscale-services) | Tailscale Services hosts via upstream `ListenService`       | Optional  | Planned          |
| [`exitNode`](#exitnode) | Route outbound traffic through another node                                | Advanced  | ✅        |
| [`prefs`](#prefs)       | Subnet routes, shields, tags, and exit-node state                    | Advanced  | ✅        |
| [`diag`](#diag)         | Ping, metrics, DERP map, and advisory native-version check           | Core      | ✅        |
| [`whois`](#whois-top-level) | Resolve a tailnet IP to node identity                             | Core      | ✅        |
| [Errors](#errors)       | Structured exception taxonomy                                        | Core      | ✅        |

## Lifecycle (top-level)

Engine lifecycle and reactive streams. These live directly on
`Tailscale.instance` rather than under a namespace because they don't
fit one topic. `up()` resolves on the **first stable state only**
(`running` / `needsLogin` / `needsMachineAuth`) so interactive auth
flows can branch on the returned status without re-calling `up()`. If
startup fails or the implementation gives up waiting before a stable
state is reached, it should throw `TailscaleUpException` rather than
returning a transitional state such as `starting`.

**Status:** fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `Tailscale.init({stateDir, appId, logLevel, noLogsNoSupport})` | ✅ | Freezes one process-wide native path/inode, local stderr level, upstream diagnostic-upload choice, and validated host-app/derived Keybay namespace identity. Upstream uploads remain enabled by default; `noLogsNoSupport: true` disables them before first startup and opts out of log-dependent support. Repeating the exact tuple is a no-op; a mismatch throws `TailscaleConfigurationException`. Initialization is lazy and performs no Keybay I/O. | `Tailscale.init(stateDir: '/app/state', appId: 'com.example.myapp');` |
| `up({hostname, authKey, ephemeral, controlUrl, timeout})` → `TailscaleStatus` | ✅ | Start engine. Persistent mode authenticates or provisions the encrypted Store through one Keybay DEK and fails closed on custody/layout errors; recognized legacy state is not migrated. `ephemeral: true` requires an auth key, uses an in-memory Store plus fresh scratch, never accesses Keybay, and rejects filesystem-visible persistent package state. Same-config active calls are idempotent and an auth key never replaces the active identity. On first upstream Running, an automatic bounded `Server.Up` reset must succeed before package Running/data-plane readiness is exposed; failure quarantines the exact generation. Timeout likewise returns only after token-qualified quarantine. | `final s = await tsnet.up(authKey: 'tskey-...', ephemeral: true);` |
| `down()` | ✅ | Stop the exact active generation and keep persisted credentials. A completed native result survives worker-response loss. Cleanup failure returns `runtimeCleanupFailed`, publishes no false clean-state transition, and blocks replacement until process restart. | `await tsnet.down();` |
| `logout()` | ✅ | Remote-first revocation. Confirmed success lets upstream remove the logical profile while preserving the encrypted StateStore container and DEK. Reconstructs a temporary runtime after `down()` using authenticated persisted state; that internal runtime stays event-silent. Failure preserves local recovery evidence and returns `logoutIndeterminate`. A confirmed result survives worker-response loss. | `await tsnet.logout();` |
| `forgetLocalIdentity()` | ✅ | Irreversible local-only reset. Stops any active runtime, durably records reset intent, deletes the exact Keybay DEK, and removes only the package-owned state subtree. It does not contact the control plane, so the remote node may remain. An interrupted reset returns `localResetIncomplete` and must be resumed with the same method. | `await tsnet.forgetLocalIdentity();` |
| `status()` → `TailscaleStatus` | ✅ | Snapshot: state, IPs, health, MagicDNS suffix. While idle, it takes the state lease and authenticates the encrypted Store through Keybay: absent/authenticated-empty is `noState`, authenticated logical state is `stopped`, and custody, legacy, tamper, or reset-marker problems fail closed with typed errors. | `final s = await tsnet.status();` |
| `nodes()` → `List<TailscaleNode>` | ✅ | Current node inventory. | `final nodes = await tsnet.nodes();` |
| `nodeByIp(ip)` → `TailscaleNode?` | ✅ | Lookup a known node by Tailscale IP from the current inventory. | `final node = await tsnet.nodeByIp('100.64.0.5');` |
| `onStateChange` → `Stream<NodeState>` | ✅ | Duplicate-filtered state transitions. Repeated `needsLogin` remains observable so callers can refresh `status().authUrl`. | `tsnet.onStateChange.listen(print);` |
| `onError` → `Stream<TailscaleRuntimeError>` | ✅ | Async runtime errors pushed from Go. Unexpected worker exit produces one `worker` incident after native quarantine and idle-state classification. | `tsnet.onError.listen(report);` |
| `onNodeChanges` → `Stream<List<TailscaleNode>>` | ✅ | Node inventory changes without polling. Replays the current inventory, emits only changes, and publishes an empty terminal snapshot after teardown so subscribers cannot retain old peers. | `tsnet.onNodeChanges.listen(render);` |

## `http`

HTTP conveniences layered on top of the tailnet. The `client` routes
every request over the tailnet tunnel; `bind` accepts incoming tailnet
HTTP and exposes package-native request/response objects backed by fd
streams. Shelf users can copy the tested adapter in
[`example/shelf_adapter.dart`](../example/shelf_adapter.dart) to run a
Shelf `Handler` directly on `http.bind` without adding Shelf as a core package
dependency.

**Status:** fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `http.client` → `http.Client` | ✅ | Drop-in `http.Client` that tunnels every request. Throws `TailscaleUsageException` before `up()`. | `await tsnet.http.client.get(peerUri);` |
| `http.bind({port})` → `TailscaleHttpServer` | ✅ | Accept tailnet HTTP requests directly. Returns a closable server with the tailnet endpoint and a single-subscription request stream. | `final server = await tsnet.http.bind(port: 80);` |

## `tcp`

Raw TCP between tailnet nodes. Verb split: `dial` for outbound (mirrors
Go's `tsnet.Server.Dial`), `bind` for inbound. Returns package-native
transport types instead of fake `dart:io` sockets: TCP is a full-duplex
`TailscaleConnection` with single-subscription `input` and an explicit
`output` write half.

**Status:** POSIX fd-backed TCP. Go owns tailnet connection
establishment and hands Dart a private fd-backed local capability.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tcp.dial(host, port, {timeout})` → `Future<TailscaleConnection>` | ✅ | Outbound TCP to a tailnet node. `host` may be IP or MagicDNS name. `timeout` bounds the native tailnet dial. | `final c = await tsnet.tcp.dial('100.64.0.5', 22);` |
| `tcp.bind({port, address})` → `Future<TailscaleListener>` | ✅ | Accept inbound TCP. `address` pins to one of this node's tailnet IPs. Pass `0` for `port` to request an ephemeral tailnet port; read it back from `listener.local.port`. | `final l = await tsnet.tcp.bind(port: 1234);` |

## `tls`

TLS-terminated listener with a cert auto-provisioned by the control
plane. Handlers see plaintext bytes — TLS is terminated server-side.

Useful for server-style apps, but not required for the package to be
valuable.

**Status:** `tls.domains()` is a read-only status query and does not use the
disabled LocalAPI certificate endpoint; it remains available as discovery and
does not imply certificate provisioning works. `tls.bind()` is implemented with
package-native fd-backed listeners on desktop/server builds and explicitly
unsupported on iOS/Android in conformance with the upstream build.
**Requires:** MagicDNS **and** HTTPS enabled on the tailnet by the
operator. Headscale CI covers only the clear unsupported failure path; live
Tailscale tests cover successful TLS serving against hosted Tailscale.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tls.bind({port, address})` → `Future<TailscaleListener>` | ✅ desktop/server; unsupported mobile | TLS-terminated listener with auto-cert. Accepted connections are plaintext package-native streams. | `final l = await tsnet.tls.bind(port: 443);` |
| `tls.domains()` → `Future<List<String>>` | ✅ discovery | Advertised cert SANs. Empty = MagicDNS or HTTPS disabled. This is not proof that `bind` can fetch a cert on the platform. | `final sans = await tsnet.tls.domains();` |

## `udp`

UDP datagram bindings over the tailnet. By default, `bind` uses this
node's current IPv4 tailnet address. Pass `address` to bind a specific
local tailnet IP. Datagrams preserve message boundaries and expose the
remote tailnet endpoint on each delivery.

**Status:** POSIX fd-backed UDP.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `udp.bind({port, address})` → `Future<TailscaleDatagramBinding>` | ✅ | UDP binding on a tailnet IP of this node. Omits `address` to use this node's IPv4. Pass `0` for an ephemeral local port; read it back from `binding.local.port`. | `final b = await tsnet.udp.bind(port: 4000);` |
| `TailscaleDatagramBinding.datagrams` → `Stream<TailscaleDatagram>` | ✅ | Single-subscription stream of received datagrams. Datagrams may be dropped while no listener is attached or the subscription is paused. | `await for (final d in b.datagrams) print(d.remote);` |
| `TailscaleDatagramBinding.send(bytes, to: endpoint)` | ✅ | Send one datagram. Payloads over 60 KiB are rejected rather than fragmented. | `await b.send(bytes, to: TailscaleEndpoint(address: nodeIp, port: 53));` |

## `funnel`

Public-internet HTTPS via Tailscale Funnel: publish an existing local HTTP
service at this node's Funnel hostname. R5 writes the same upstream ServeConfig
handler used by Serve and enables `AllowFunnel` for its host and port. There is
no package-owned Funnel listener or reverse-proxy loop.

`AllowFunnel` is host:port-scoped, not path-scoped. Enabling Funnel for one path
can make every handler on that port publicly reachable. Use a dedicated public
port or authenticate every handler sharing it.

This is explicitly optional: useful for some hosted/server apps, but
not part of the core embedded-private-network story.

**Status:** implemented and desktop/server-qualified for local HTTP forwarding.
The R5 hosted Funnel-tailnet and Serve/Funnel swap tests passed on 2026-08-10;
the shared ServeConfig first-`Up` reset also has a macOS production-Keybay
process-crash/restart receipt through a private Serve mapping. Mobile remains
unqualified pending separate device handshakes and sidecar inventory.
**Requires:** the operator has enabled HTTPS and Funnel for this node and an
allowed Funnel port (usually 443, 8443, or 10000). Headscale doesn't support
Funnel, so public ingress requires hosted Tailscale evidence.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `funnel.forward({publicPort, localPort, localAddress, path})` → `Future<TailscalePublishedService>` | ✅ desktop/server; mobile unqualified | Make the shared ServeConfig mapping publicly reachable. A later Serve/Funnel call at the same coordinate replaces it. | `final p = await tsnet.funnel.forward(localPort: 3000);` |
| `funnel.clear({publicPort, path})` | ✅ desktop/server; mobile unqualified | Coordinate clear: remove the shared handler and disable Funnel visibility for its host/port. | `await tsnet.funnel.clear();` |
| `TailscalePublishedService.close()` | ✅ where publication is supported | Remove the publication created by `forward`. Idempotent per handle. | `await p.close();` |

## `serve`

Programmatic access to what `tailscale serve` / `tailscale funnel` do
on the CLI: HTTP routing and public-internet publishing.

`serve.forward` publishes an existing loopback HTTP server inside the
tailnet. `localAddress` must be loopback (`127.0.0.1`, `::1`, or
`localhost`) so callers cannot accidentally publish arbitrary host-reachable
endpoints. `http.bind()` remains the package-native in-process HTTP server and
should be preferred when the handler lives in Dart and does not need a local TCP
listener.

For tailnet clients, Serve follows upstream Tailscale Serve semantics and
forwards Tailscale identity headers such as `Tailscale-User-Login`,
`Tailscale-User-Name`, and `Tailscale-User-Profile-Pic` to the loopback backend.
Public Funnel traffic does not include those identity headers.

Serve/Funnel publications created by this package are process-scoped rather
than persistent `tailscale serve --bg` configuration. Close the returned
`TailscalePublishedService` explicitly; `Tailscale.down()` also removes
package-created publications best-effort before stopping the embedded node.
Serve and Funnel share one coordinate namespace. The latest forward at a
port/path owns the handler and visibility mode; `close()` is exact-token and
cannot remove a same-generation replacement or a mapping from a newer runtime.

**Status:** implemented for local HTTP forwarding. Desktop/server HTTPS and the
R5 swap/exact-handle sequence plus a macOS production-Keybay persisted process-
crash/restart sequence have hosted-Tailscale receipts, most recently 2026-08-10.
Mobile HTTPS Serve remains pending and requires its own real-device and sidecar
receipts. Raw `ServeConfig` get/set remains a possible future escape hatch.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `serve.forward({tailnetPort, localPort, localAddress, path, https})` → `Future<TailscalePublishedService>` | ✅ desktop/server HTTPS; mobile HTTPS unqualified | Publish a local HTTP service inside the tailnet. | `final p = await tsnet.serve.forward(tailnetPort: 443, localPort: 3000);` |
| `serve.clear({tailnetPort, path})` | ✅ | Remove a tailnet Serve publication. | `await tsnet.serve.clear(tailnetPort: 443);` |
| `TailscalePublishedService` | ✅ | Publication handle with `url`, local target metadata, and `close()`. | `print(p.url); await p.close();` |

## Tailscale Services

Upstream `tsnet.Server.ListenService` advertises a named Tailscale Service from
a tagged node. It is available in the current upstream pin but is not exposed by
this package yet.

**Status:** planned after the public Dart shape is designed.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `services.*` | ⛔ | No public Dart API yet. Likely future shape mirrors `tsnet.Server.ListenService` while preserving package-native listener types. | N/A |

## `exitNode`

Route all outbound traffic from this node through another node (VPN-style).
Use `use(node)` when you have a `TailscaleNode` in hand, `useById(id)`
when only the stable ID is durable (persisted across sessions), or
`useAuto()` to let the control plane pick by latency and re-pick on
changes.

Advanced node-control feature; useful, but not central to the core
embedded-app value proposition.

**Status:** implemented. Headscale covers prefs write/read mechanics; the
on-demand live Tailscale suite covers `suggest` / `useAuto` behavior because
recommendation policy is control-plane-specific.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `exitNode.current()` → `Future<TailscaleNode?>` | ✅ | Node currently used as exit, or null. | `final cur = await tsnet.exitNode.current();` |
| `exitNode.suggest()` → `Future<TailscaleNode?>` | ✅ | Control-plane-recommended exit (latency-based). | `final s = await tsnet.exitNode.suggest();` |
| `exitNode.use(TailscaleNode)` | ✅ | Route through this node. Type-safe. | `await tsnet.exitNode.use(node);` |
| `exitNode.useById(stableNodeId)` | ✅ | Escape hatch when only the stable ID is available. | `await tsnet.exitNode.useById('nAbCd');` |
| `exitNode.useAuto()` | ✅ | `AutoExitNode` mode — control plane picks and re-picks. | `await tsnet.exitNode.useAuto();` |
| `exitNode.clear()` | ✅ | Stop routing through an exit node. | `await tsnet.exitNode.clear();` |
| `exitNode.onCurrentChange` → `Stream<TailscaleNode?>` | ✅ | React to runtime exit-node selection changes. | `tsnet.exitNode.onCurrentChange.listen(update);` |

## `prefs`

The supported long tail of node preferences — subnet routes, shields, and
advertised tags. Current hostname and running intent are readable snapshots,
but lifecycle authority stays with `up()` / `down()`. Common single-field
changes have named setters (`set*` prefix for consistency); atomic multi-field
edits use `updateMasked(PrefsUpdate)`.
Advanced node-control surface rather than core day-one app plumbing.

**Status:** implemented. Headscale covers LocalAPI prefs write/read behavior;
the on-demand live Tailscale suite covers exit-node recommendation policy.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `prefs.get()` → `Future<TailscalePrefs>` | ✅ | Current prefs snapshot. | `final p = await tsnet.prefs.get();` |
| `prefs.setAdvertisedRoutes(cidrs)` | ✅ | Replace advertised subnet routes. | `await tsnet.prefs.setAdvertisedRoutes(['10.0.0.0/24']);` |
| `prefs.setAcceptRoutes(bool)` | ✅ | Accept subnet routes from other nodes. | `await tsnet.prefs.setAcceptRoutes(true);` |
| `prefs.setShieldsUp(bool)` | ✅ | Block all inbound connections. | `await tsnet.prefs.setShieldsUp(true);` |
| `prefs.setAdvertisedTags(tags)` | ✅ | Replace advertised ACL tags. | `await tsnet.prefs.setAdvertisedTags(['tag:prod']);` |
| `prefs.updateMasked(PrefsUpdate)` | ✅ | Atomic routes, Shields Up, tags, and exit-node edit; unset fields stay as-is. | `await tsnet.prefs.updateMasked(PrefsUpdate(shieldsUp: true));` |

## `diag`

Observability and diagnostics. Read-only — nothing here affects
connectivity. `ping` is Tailscale's own Disco probe by default (not
ICMP).

**Status:** fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `diag.ping(ip, {timeout, type})` → `Future<PingResult>` | ✅ | RTT + route diagnostic. `PingResult.path` distinguishes `direct`, `derp`, and `unknown` when the chosen ping type does not expose enough metadata. `type` is one of `disco` (default, no privileges), `tsmp`, `icmp`. | `final r = await tsnet.diag.ping('100.64.0.5');` |
| `diag.metrics()` → `Future<String>` | ✅ | Prometheus-format metrics snapshot from the embedded runtime. | `print(await tsnet.diag.metrics());` |
| `diag.derpMap()` → `Future<DERPMap>` | ✅ | Current DERP relay map. | `final m = await tsnet.diag.derpMap();` |
| `diag.checkUpdate()` → `Future<ClientVersion?>` | ✅ | Advisory newer native Tailscale version, else null. Upgrade the package or host app to apply it; the embedded runtime cannot replace itself. | `final v = await tsnet.diag.checkUpdate();` |
| `PingResult`, `DERPMap`, `DERPRegion`, `DERPNode`, `ClientVersion` value types | ✅ | Immutable returns with `==` / `hashCode`. | `switch (ping.path) { ... }` |

## `whois` (top-level)

Resolve a tailnet IP to node identity (node ID, hostname, owner login,
ACL tags). Lives flat on `Tailscale` rather than under a namespace
because it's a single cross-cutting utility — commonly paired with
`tcp.bind` to authorize inbound connections by tag.

**Status:** fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `whois(ip)` → `Future<TailscaleNodeIdentity?>` | ✅ | Identity by tailnet IP; null if not known. | `final id = await tsnet.whois(conn.remoteAddress.address);` |
| `TailscaleNodeIdentity` value type | ✅ | `nodeId`, `hostName`, `userLoginName`, `tags`, `tailscaleIPs`. | `id.tags.contains('tag:trusted')` |

## Errors

Every operation-specific failure extends `TailscaleOperationException`
and carries a structured `TailscaleErrorCode` + optional HTTP
`statusCode`. Callers pattern-match on the exception type (per
namespace) and branch on `code` for outcomes (retry on `conflict`,
surface `featureDisabled`, rethrow otherwise).

**Status:** fully working.

| Type | Status | Thrown by | Example |
| ---- | ------ | --------- | ------- |
| `TailscaleErrorCode` enum | ✅ | Includes lifecycle codes plus secure-state outcomes such as `stateLeaseBusy`, `missingStateKey`, `orphanedStateKey`, `localResetIncomplete`, `legacyStateUnsupported`, `stateAuthenticationFailed`, `invalidStateFormat`, `secureStorageLocked`, and `secureStorageUnavailable`; LocalAPI codes; and `unknown`. | `if (e.code == TailscaleErrorCode.secureStorageLocked) retryLater();` |
| `TailscaleUsageException` | ✅ | Misuse: `http.client` before `up()`, empty `stateDir`, invalid `appId`, etc. | `on TailscaleUsageException catch (_) { ... }` |
| `TailscaleConfigurationException` | ✅ | A repeated `init` conflicts with the process-owned state root, Keybay namespace, or logging policy. | `on TailscaleConfigurationException catch (_) { ... }` |
| `TailscaleUpException` | ✅ | `up()` failed before reaching a stable state. | `on TailscaleUpException catch (e) { showAuth(e); }` |
| `TailscaleHttpException` | ✅ | `http.*`. | `on TailscaleHttpException catch (_) { ... }` |
| `TailscaleStatusException` | ✅ | `status()`. | `on TailscaleStatusException catch (_) { ... }` |
| `TailscaleLogoutException` | ✅ | `logout()`. | `on TailscaleLogoutException catch (_) { ... }` |
| `TailscaleForgetLocalIdentityException` | ✅ | `forgetLocalIdentity()`. | `on TailscaleForgetLocalIdentityException catch (_) { ... }` |
| `TailscaleServeException` | ✅ | `serve.*` incl. ETag conflicts. | `on TailscaleServeException catch (e) { ... }` |
| `TailscalePrefsException` | ✅ | `prefs.*`. | `on TailscalePrefsException catch (_) { ... }` |
| `TailscaleExitNodeException` | ✅ | `exitNode.*`. | `on TailscaleExitNodeException catch (_) { ... }` |
| `TailscaleDiagException` | ✅ | `diag.*`. | `on TailscaleDiagException catch (_) { ... }` |
| `TailscaleRuntimeError` (not `Exception`) | ✅ | Async errors pushed from Go via `onError`. | `tsnet.onError.listen((e) => report(e));` |
