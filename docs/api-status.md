# API status & usage

Reference for the public API surface of `package:tailscale`, grouped by
namespace. For each namespace: a description, the phase that completes
it, and a table of APIs with status, purpose, and a copy-pasteable
example. For the forward-looking phase plan, see
[`api-roadmap.md`](api-roadmap.md).

The **core v1 path** is lifecycle + private HTTP/TCP +
identity/diagnostics + the LocalAPI escape hatch. Advanced/optional
namespaces remain tracked here, but they do not block a useful v1 for
embedded Dart apps.

**Legend:**
- ✅ Working — callable today, tested, returns real values.
- ⛔ Stub — typed + documented, throws `UnimplementedError`.

**Convention:** all examples assume `final tsnet = Tailscale.instance;`
and that [`Tailscale.init`](#lifecycle-top-level) has already been called.

**Implementation model:** this package aligns to both upstream
`tsnet.Server` and upstream `local.Client`. Transport primitives such as
HTTP, TCP, UDP, TLS, Funnel, and future service listeners follow
`tsnet`; node introspection, diagnostics, prefs, profiles, serve
config, exit nodes, and taildrop follow LocalAPI via `local.Client`.

**Version note:** the current repo pin is `tailscale.com v1.92.2`. Some
upstream APIs documented below as planned alignment work, especially
Tailscale Services hosting via `tsnet.Server.ListenService`, require a
module bump before they can land here.

## Namespace overview

| Namespace               | Feature                                                           | Track     | Status           |
| ----------------------- | ----------------------------------------------------------------- | --------- | ---------------- |
| [Lifecycle](#lifecycle-top-level) | Engine start/stop + node state snapshot + reactive streams | Core      | Phase 1 ✅        |
| [`http`](#http)         | Outbound HTTP client + inbound request server                     | Core      | Phase 1 ✅        |
| [`tcp`](#tcp)           | Raw TCP between tailnet nodes                                      | Core      | Phase 3 ✅        |
| [`tls`](#tls)           | TLS-terminated listener with auto-provisioned cert                 | Advanced  | `domains` ✅; `bind` planned |
| [`udp`](#udp)           | UDP datagram bindings on a tailnet IP                               | Advanced  | Phase 5 ✅        |
| [`funnel`](#funnel)     | Public-internet HTTPS via Tailscale Funnel                         | Optional  | Planned          |
| [`taildrop`](#taildrop) | Node-to-node file transfer                                          | Optional  | Planned          |
| [`serve`](#serve)       | Raw `tailscale serve` / `tailscale funnel` config                   | Optional  | Planned          |
| [`exitNode`](#exitnode) | Route outbound traffic through another node                                | Advanced  | Planned          |
| [`profiles`](#profiles) | Multi-account / multi-tailnet                                        | Optional  | Planned          |
| [`prefs`](#prefs)       | Subnet routes, shields, tags, auto-update                           | Advanced  | Planned          |
| [`diag`](#diag)         | Ping, metrics, DERP map, update check                                | Core      | Phase 4 ✅        |
| [`whois`](#whois-top-level) | Resolve a tailnet IP to node identity                             | Core      | Phase 4 ✅        |
| [Errors](#errors)       | Structured exception taxonomy                                        | Core      | Phase 2 ✅        |

## Lifecycle (top-level)

Engine lifecycle and reactive streams. These live directly on
`Tailscale.instance` rather than under a namespace because they don't
fit one topic. `up()` resolves on the **first stable state only**
(`running` / `needsLogin` / `needsMachineAuth`) so interactive auth
flows can branch on the returned status without re-calling `up()`. If
startup fails or the implementation gives up waiting before a stable
state is reached, it should throw `TailscaleUpException` rather than
returning a transitional state such as `starting`.

**Completed in:** Phase 1 (parity) — fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `Tailscale.init({stateDir, logLevel})` | ✅ | One-time library configuration at app startup. | `Tailscale.init(stateDir: '/app/state');` |
| `up({hostname, authKey, controlUrl})` → `TailscaleStatus` | ✅ | Start engine; resolves on the first stable state only. Throws `TailscaleUpException` if startup fails before that. | `final s = await tsnet.up(authKey: 'tskey-...');` |
| `down()` | ✅ | Stop engine, keep persisted credentials. | `await tsnet.down();` |
| `logout()` | ✅ | Stop + wipe persisted credentials. | `await tsnet.logout();` |
| `status()` → `TailscaleStatus` | ✅ | Snapshot: state, IPs, health, MagicDNS suffix. | `final s = await tsnet.status();` |
| `nodes()` → `List<TailscaleNode>` | ✅ | Current node inventory. | `final nodes = await tsnet.nodes();` |
| `nodeByIp(ip)` → `TailscaleNode?` | ✅ | Lookup a known node by Tailscale IP from the current inventory. | `final node = await tsnet.nodeByIp('100.64.0.5');` |
| `onStateChange` → `Stream<NodeState>` | ✅ | Duplicate-filtered state transitions. Repeated `needsLogin` remains observable so callers can refresh `status().authUrl`. | `tsnet.onStateChange.listen(print);` |
| `onError` → `Stream<TailscaleRuntimeError>` | ✅ | Async runtime errors pushed from Go. | `tsnet.onError.listen(report);` |
| `onNodeChanges` → `Stream<List<TailscaleNode>>` | ✅ | Node inventory changes without polling. Replays the current inventory to new subscribers, then emits only when the node list actually changes. | `tsnet.onNodeChanges.listen(render);` |

## `http`

HTTP conveniences layered on top of the tailnet. The `client` routes
every request over the tailnet tunnel; `bind` accepts incoming tailnet
HTTP and exposes package-native request/response objects backed by fd
streams.

**Completed in:** Phase 1 — fully working.

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

**Completed in:** Phase 3 — POSIX fd-backed TCP. Go owns tailnet connection
establishment and hands Dart a private fd-backed local capability.

**Tracked upstream gap:** `tsnet.Server.ListenService` exists upstream
as of `tailscale.com v1.94.1`, but is not yet exposed here. The roadmap
tracks that as a future `tcp`-aligned listener once the module pin is
bumped; it should not force a separate `services` namespace by itself.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tcp.dial(host, port, {timeout})` → `Future<TailscaleConnection>` | ✅ | Outbound TCP to a tailnet node. `host` may be IP or MagicDNS name. `timeout` bounds the native tailnet dial. | `final c = await tsnet.tcp.dial('100.64.0.5', 22);` |
| `tcp.bind({port, address})` → `Future<TailscaleListener>` | ✅ | Accept inbound TCP. `address` pins to one of this node's tailnet IPs. Pass `0` for `port` to request an ephemeral tailnet port; read it back from `listener.local.port`. | `final l = await tsnet.tcp.bind(port: 1234);` |

## `tls`

TLS-terminated listener with a cert auto-provisioned by the control
plane. Handlers see plaintext bytes — TLS is terminated server-side.

Useful for server-style apps, but not required for the package to be
valuable.

**Status:** `tls.domains()` is working. `tls.bind()` is planned.
**Requires:** MagicDNS **and** HTTPS enabled on the tailnet by the
operator. Not covered by the Headscale CI — live-Tailscale test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tls.bind(port)` → `Future<SecureServerSocket>` | ⛔ | TLS-terminated listener with auto-cert. | `final srv = await tsnet.tls.bind(443);` |
| `tls.domains()` → `Future<List<String>>` | ✅ | Cert SANs; preflight for `bind`. Empty = MagicDNS or HTTPS disabled on the tailnet. | `final sans = await tsnet.tls.domains();` |

## `udp`

UDP datagram bindings over the tailnet. By default, `bind` uses this
node's current IPv4 tailnet address. Pass `address` to bind a specific
local tailnet IP. Datagrams preserve message boundaries and expose the
remote tailnet endpoint on each delivery.

**Completed in:** Phase 5 — POSIX fd-backed UDP.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `udp.bind({port, address})` → `Future<TailscaleDatagramBinding>` | ✅ | UDP binding on a tailnet IP of this node. Omits `address` to use this node's IPv4. Pass `0` for an ephemeral local port; read it back from `binding.local.port`. | `final b = await tsnet.udp.bind(port: 4000);` |
| `TailscaleDatagramBinding.datagrams` → `Stream<TailscaleDatagram>` | ✅ | Single-subscription stream of received datagrams. Datagrams may be dropped while no listener is attached or the subscription is paused. | `await for (final d in b.datagrams) print(d.remote);` |
| `TailscaleDatagramBinding.send(bytes, to: endpoint)` | ✅ | Send one datagram. Payloads over 60 KiB are rejected rather than fragmented. | `await b.send(bytes, to: TailscaleEndpoint(address: nodeIp, port: 53));` |

## `funnel`

Public-internet HTTPS via Tailscale Funnel: the node is reachable from
the open internet at its Funnel hostname, with edge TLS termination.
The Funnel edge attaches `publicSrc` + `sni` metadata to each accepted
socket; read it via the `Socket.funnel` extension — this lets `bind`
return a standard `SecureServerSocket` instead of a `dart:io` subclass.

This is explicitly optional: useful for some hosted/server apps, but
not part of the core embedded-private-network story.

**Status:** planned. **Requires:** operator has enabled Funnel
in ACLs for this node and an allowed Funnel port (443, 8443, 10000).
Headscale doesn't support Funnel; live-Tailscale test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `funnel.bind(port, {funnelOnly})` → `Future<SecureServerSocket>` | ⛔ | Public-internet TLS listener. `funnelOnly: true` rejects same-tailnet clients. | `final srv = await tsnet.funnel.bind(443);` |
| `FunnelMetadata` value type (`publicSrc`, `sni`) | ✅ | Metadata the Funnel edge attached to a socket. | `const FunnelMetadata(publicSrc: ...);` |
| `Socket.funnel` extension getter | ✅ | Read `FunnelMetadata` off an accepted socket; null if not from Funnel. | `final meta = conn.funnel;` |

## `taildrop`

Node-to-node file transfer ("Taildrop") over the tailnet. Sends go
directly between nodes with no intermediary — good fit for
mobile-to-desktop sync, collab tools, anywhere you'd otherwise stand up
a file server. Byte streams use `Stream<Uint8List>` throughout so
producer/consumer can pipe without intermediate buffering.

This remains optional. Upstream Taildrop is still aimed at transfers
between a user's own personal devices, so it is not a strong fit for
generic tagged-node or service-to-service workflows.

**Status:** planned. **Depends on:** the simplest stream-safe
byte path available at the time, likely fd-backed transport or a
LocalAPI-backed byte stream.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `taildrop.targets()` → `Future<List<FileTarget>>` | ⛔ | Nodes eligible to receive files right now. | `final ts = await tsnet.taildrop.targets();` |
| `taildrop.push({target, name, data, size?})` | ⛔ | Stream a file to a node. `size` enables receiver progress reporting. | `await tsnet.taildrop.push(target: t, name: 'x', data: bytes);` |
| `taildrop.waitingFiles()` → `Future<List<WaitingFile>>` | ⛔ | Received files not yet picked up. | `final files = await tsnet.taildrop.waitingFiles();` |
| `taildrop.awaitWaitingFiles({timeout})` | ⛔ | Block until at least one file arrives or timeout fires. | `await tsnet.taildrop.awaitWaitingFiles(timeout: ...);` |
| `taildrop.openRead(name)` → `Stream<Uint8List>` | ⛔ | Byte-stream a received file. Caller owns persistence. | `tsnet.taildrop.openRead('x').pipe(sink);` |
| `taildrop.delete(name)` | ⛔ | Discard a received file without reading. | `await tsnet.taildrop.delete('x');` |
| `taildrop.onWaitingFile` → `Stream<WaitingFile>` | ⛔ | Reactive: emits each arriving file. | `tsnet.taildrop.onWaitingFile.listen(save);` |
| `FileTarget` value type | ✅ | Node identity (nodeId, hostname, userLoginName). | `target.hostname == 'laptop'` |
| `WaitingFile` value type | ✅ | Name + size of a received file. | `file.size > 0` |

## `serve`

Programmatic access to what `tailscale serve` / `tailscale funnel` do
on the CLI: HTTP routing and public-internet publishing. `ServeConfig`
carries an opaque `etag` for optimistic concurrency — if another
writer lands first, `setConfig` throws `TailscaleServeException` with
`TailscaleErrorCode.conflict`.

This is tracked as an optional raw-config surface, not as a rich Dart
builder API. `http.bind()` remains the main package-native HTTP-publish
feature for typical Dart apps.

**Status:** planned. **Depends on:** Phase 2 (value types).
**Also:** Phase 9 bumps the `tailscale.com` Go module pin to pick up
`Services` / `AllowFunnel` / `Foreground` and the newer
service-adjacent APIs. Headscale doesn't support Serve; live-Tailscale
test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `serve.getConfig()` → `Future<ServeConfig>` | ⛔ | Current serve/funnel config for this node. | `final cfg = await tsnet.serve.getConfig();` |
| `serve.setConfig(ServeConfig)` | ⛔ | Replace atomically; throws on ETag mismatch. | `await tsnet.serve.setConfig(updated);` |
| `ServeConfig` value type (with `etag`) | ✅ | Immutable config object; handler modeling lands in Phase 9. | `const ServeConfig(etag: 'v1');` |

## `exitNode`

Route all outbound traffic from this node through another node (VPN-style).
Use `use(node)` when you have a `TailscaleNode` in hand, `useById(id)`
when only the stable ID is durable (persisted across sessions), or
`useAuto()` to let the control plane pick by latency and re-pick on
changes.

Advanced node-control feature; useful, but not central to the core
embedded-app value proposition.

**Status:** planned.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `exitNode.current()` → `Future<TailscaleNode?>` | ⛔ | Node currently used as exit, or null. | `final cur = await tsnet.exitNode.current();` |
| `exitNode.suggest()` → `Future<TailscaleNode?>` | ⛔ | Control-plane-recommended exit (latency-based). | `final s = await tsnet.exitNode.suggest();` |
| `exitNode.use(TailscaleNode)` | ⛔ | Route through this node. Type-safe. | `await tsnet.exitNode.use(node);` |
| `exitNode.useById(stableNodeId)` | ⛔ | Escape hatch when only the stable ID is available. | `await tsnet.exitNode.useById('nAbCd');` |
| `exitNode.useAuto()` | ⛔ | `AutoExitNode` mode — control plane picks and re-picks. | `await tsnet.exitNode.useAuto();` |
| `exitNode.clear()` | ⛔ | Stop routing through an exit node. | `await tsnet.exitNode.clear();` |
| `exitNode.onCurrentChange` → `Stream<TailscaleNode?>` | ⛔ | React to changes (incl. external, from another signed-in device). | `tsnet.exitNode.onCurrentChange.listen(update);` |

## `profiles`

Multi-account / multi-tailnet: one device, several identities. Useful
for a single app operating in both a personal and a work tailnet, or
dev vs prod. `switchTo` accepts a `LoginProfile` (type-safe) or use
`switchToId` when you've persisted only the ID.

Tracked as optional. If the package stays focused on "embed one node in
one app", this may never be a common need.

**Status:** planned.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `profiles.current()` → `Future<LoginProfile?>` | ⛔ | Currently active profile, or null on a fresh install. | `final p = await tsnet.profiles.current();` |
| `profiles.list()` → `Future<List<LoginProfile>>` | ⛔ | All profiles persisted on this node. | `final all = await tsnet.profiles.list();` |
| `profiles.switchTo(LoginProfile)` | ⛔ | Disconnect + reconnect with the target profile. | `await tsnet.profiles.switchTo(work);` |
| `profiles.switchToId(id)` | ⛔ | Escape hatch for a persisted ID. | `await tsnet.profiles.switchToId('p1');` |
| `profiles.delete(LoginProfile)` | ⛔ | Remove profile + its persisted credentials. | `await tsnet.profiles.delete(old);` |
| `profiles.deleteById(id)` | ⛔ | Escape hatch for delete by ID. | `await tsnet.profiles.deleteById('p1');` |
| `profiles.newEmpty()` | ⛔ | Create an empty slot for the next `up()` with a fresh authkey. | `await tsnet.profiles.newEmpty();` |
| `LoginProfile` value type | ✅ | `id`, `userLoginName`, `tailnetName`. | `profile.tailnetName == 'acme.com'` |

## `prefs`

The long tail of node preferences — subnet routes, shields, advertised
tags, auto-update opt-in. Common single-field changes have named
setters (`set*` prefix for consistency); atomic multi-field edits use
`updateMasked(PrefsUpdate)`.
Advanced node-control surface rather than core day-one app plumbing.

**Status:** planned.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `prefs.get()` → `Future<TailscalePrefs>` | ⛔ | Current prefs snapshot. | `final p = await tsnet.prefs.get();` |
| `prefs.setAdvertisedRoutes(cidrs)` | ⛔ | Replace advertised subnet routes. | `await tsnet.prefs.setAdvertisedRoutes(['10.0.0.0/24']);` |
| `prefs.setAcceptRoutes(bool)` | ⛔ | Accept subnet routes from other nodes. | `await tsnet.prefs.setAcceptRoutes(true);` |
| `prefs.setShieldsUp(bool)` | ⛔ | Block all inbound connections. | `await tsnet.prefs.setShieldsUp(true);` |
| `prefs.setAutoUpdate(bool)` | ⛔ | Opt in/out of tsnet auto-update. | `await tsnet.prefs.setAutoUpdate(true);` |
| `prefs.setAdvertisedTags(tags)` | ⛔ | Replace advertised ACL tags. | `await tsnet.prefs.setAdvertisedTags(['tag:prod']);` |
| `prefs.updateMasked(PrefsUpdate)` | ⛔ | Atomic multi-field edit; unset fields stay as-is. | `await tsnet.prefs.updateMasked(PrefsUpdate(shieldsUp: true));` |

## `diag`

Observability and diagnostics. Read-only — nothing here affects
connectivity. `ping` is Tailscale's own Disco probe by default (not
ICMP).

**Completed in:** Phase 4 (`ping`, `metrics`, `derpMap`, `checkUpdate`).

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `diag.ping(ip, {timeout, type})` → `Future<PingResult>` | ✅ | RTT + route diagnostic. `PingResult.path` distinguishes `direct`, `derp`, and `unknown` when the chosen ping type does not expose enough metadata. `type` is one of `disco` (default, no privileges), `tsmp`, `icmp`. | `final r = await tsnet.diag.ping('100.64.0.5');` |
| `diag.metrics()` → `Future<String>` | ✅ | Prometheus-format metrics snapshot from the embedded runtime. | `print(await tsnet.diag.metrics());` |
| `diag.derpMap()` → `Future<DERPMap>` | ✅ | Current DERP relay map. | `final m = await tsnet.diag.derpMap();` |
| `diag.checkUpdate()` → `Future<ClientVersion?>` | ✅ | Newer version if available, else null. Fields match `tailcfg.ClientVersion` (latestVersion, urgentSecurityUpdate, notifyText). | `final v = await tsnet.diag.checkUpdate();` |
| `PingResult`, `DERPMap`, `DERPRegion`, `DERPNode`, `ClientVersion` value types | ✅ | Immutable returns with `==` / `hashCode`. | `switch (ping.path) { ... }` |

## `whois` (top-level)

Resolve a tailnet IP to node identity (node ID, hostname, owner login,
ACL tags). Lives flat on `Tailscale` rather than under a namespace
because it's a single cross-cutting utility — commonly paired with
`tcp.bind` to authorize inbound connections by tag.

**Completed in:** Phase 4.

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

**Completed in:** Phase 2 — fully working.

| Type | Status | Thrown by | Example |
| ---- | ------ | --------- | ------- |
| `TailscaleErrorCode` enum | ✅ | `notFound` / `forbidden` / `conflict` / `preconditionFailed` / `featureDisabled` / `unknown`. | `if (e.code == TailscaleErrorCode.conflict) retry();` |
| `TailscaleUsageException` | ✅ | Misuse: `http.client` before `up()`, empty `stateDir`, etc. | `on TailscaleUsageException catch (_) { ... }` |
| `TailscaleUpException` | ✅ | `up()` failed before reaching a stable state. | `on TailscaleUpException catch (e) { showAuth(e); }` |
| `TailscaleHttpException` | ✅ | `http.*`. | `on TailscaleHttpException catch (_) { ... }` |
| `TailscaleStatusException` | ✅ | `status()`. | `on TailscaleStatusException catch (_) { ... }` |
| `TailscaleLogoutException` | ✅ | `logout()`. | `on TailscaleLogoutException catch (_) { ... }` |
| `TailscaleTaildropException` | ✅ | `taildrop.*`. | `on TailscaleTaildropException catch (_) { ... }` |
| `TailscaleServeException` | ✅ | `serve.*` incl. ETag conflicts. | `on TailscaleServeException catch (e) { ... }` |
| `TailscalePrefsException` | ✅ | `prefs.*`. | `on TailscalePrefsException catch (_) { ... }` |
| `TailscaleProfilesException` | ✅ | `profiles.*`. | `on TailscaleProfilesException catch (_) { ... }` |
| `TailscaleExitNodeException` | ✅ | `exitNode.*`. | `on TailscaleExitNodeException catch (_) { ... }` |
| `TailscaleDiagException` | ✅ | `diag.*`. | `on TailscaleDiagException catch (_) { ... }` |
| `TailscaleRuntimeError` (not `Exception`) | ✅ | Async errors pushed from Go via `onError`. | `tsnet.onError.listen((e) => report(e));` |
