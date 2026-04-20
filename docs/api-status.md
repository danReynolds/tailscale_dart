# API status & usage

Reference for the public API surface of `package:tailscale`, grouped by
namespace. For each namespace: a description, the phase that completes
it, and a table of APIs with status, purpose, and a copy-pasteable
example. For the forward-looking phase plan, see
[`api-roadmap.md`](api-roadmap.md).

**Legend:**
- ✅ Working — callable today, tested, returns real values.
- ⛔ Stub — typed + documented, throws `UnimplementedError`.

**Convention:** all examples assume `final tsnet = Tailscale.instance;`
and that [`Tailscale.init`](#lifecycle-top-level) has already been called.

## Namespace overview

| Namespace               | Feature                                                           | Completed in     |
| ----------------------- | ----------------------------------------------------------------- | ---------------- |
| [Lifecycle](#lifecycle-top-level) | Engine start/stop + node state snapshot + reactive streams | Phase 1 ✅        |
| [`http`](#http)         | HTTP over the tailnet + reverse-proxy helper                      | Phase 1 ✅        |
| [`tcp`](#tcp)           | Raw TCP between tailnet peers                                      | Phase 3          |
| [`tls`](#tls)           | TLS-terminated listener with auto-provisioned cert                 | Phase 4–5        |
| [`udp`](#udp)           | UDP datagram sockets on a tailnet IP                                | Phase 5          |
| [`funnel`](#funnel)     | Public-internet HTTPS via Tailscale Funnel                         | Phase 5          |
| [`taildrop`](#taildrop) | Peer-to-peer file transfer                                          | Phase 8          |
| [`serve`](#serve)       | `tailscale serve` / `tailscale funnel` config                        | Phase 9          |
| [`exitNode`](#exitnode) | Route outbound traffic through a peer                                | Phase 6          |
| [`profiles`](#profiles) | Multi-account / multi-tailnet                                        | Phase 7          |
| [`prefs`](#prefs)       | Subnet routes, shields, tags, auto-update                           | Phase 6          |
| [`diag`](#diag)         | Ping, metrics, DERP map, update check                                | Phase 4 + 10     |
| [`whois`](#whois-top-level) | Resolve a tailnet IP to peer identity                             | Phase 4          |
| [Errors](#errors)       | Structured exception taxonomy                                        | Phase 2 ✅        |

## Lifecycle (top-level)

Engine lifecycle and reactive streams. These live directly on
`Tailscale.instance` rather than under a namespace because they don't
fit one topic. `up()` resolves on the **first stable state** (`running`
/ `needsLogin` / `needsMachineAuth`) so interactive auth flows can
branch on the returned status without re-calling `up()`.

**Completed in:** Phase 1 (parity) — fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `Tailscale.init({stateDir, logLevel})` | ✅ | One-time library configuration at app startup. | `Tailscale.init(stateDir: '/app/state');` |
| `up({hostname, authKey, controlUrl})` → `TailscaleStatus` | ✅ | Start engine; resolves on first stable state. | `final s = await tsnet.up(authKey: 'tskey-...');` |
| `down()` | ✅ | Stop engine, keep persisted credentials. | `await tsnet.down();` |
| `logout()` | ✅ | Stop + wipe persisted credentials. | `await tsnet.logout();` |
| `status()` → `TailscaleStatus` | ✅ | Snapshot: state, IPs, health, MagicDNS suffix. | `final s = await tsnet.status();` |
| `peers()` → `List<PeerStatus>` | ✅ | Current peer inventory. | `final peers = await tsnet.peers();` |
| `onStateChange` → `Stream<NodeState>` | ✅ | Distinct-filtered state transitions. | `tsnet.onStateChange.listen(print);` |
| `onError` → `Stream<TailscaleRuntimeError>` | ✅ | Async runtime errors pushed from Go. | `tsnet.onError.listen(report);` |
| `onPeersChange` → `Stream<List<PeerStatus>>` | ⛔ | Peer inventory changes without polling. | `tsnet.onPeersChange.listen(render);` |

## `http`

HTTP conveniences layered on top of the tailnet. The `client` routes
every request over the tailnet tunnel; `expose` forwards incoming
tailnet HTTP to a local server, so existing `shelf` / `dart_frog`
stacks work unchanged.

**Completed in:** Phase 1 — fully working.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `http.client` → `http.Client` | ✅ | Drop-in `http.Client` that tunnels every request. Throws `TailscaleUsageException` before `up()`. | `await tsnet.http.client.get(peerUri);` |
| `http.expose(localPort, {tailnetPort})` → `int` | ✅ | Forward tailnet traffic to a local HTTP server. Returns the effective local port. | `await tsnet.http.expose(8080, tailnetPort: 80);` |

## `tcp`

Raw TCP between tailnet peers. Verb split: `dial` for outbound (mirrors
Go's `tsnet.Server.Dial`), `bind` for inbound (mirrors
`ServerSocket.bind` in `dart:io`). Returns standard `dart:io` types so
accept loops are just `await for (conn in server)`.

**Completed in:** Phase 3 — depends on the shared loopback-bridge
helper in Go, which also unblocks TLS / UDP / Funnel / Taildrop.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tcp.dial(host, port, {timeout})` → `Future<Socket>` | ⛔ | Outbound TCP to a tailnet peer. `host` may be IP or MagicDNS name. | `final s = await tsnet.tcp.dial('100.64.0.5', 22);` |
| `tcp.bind(port, {host})` → `Future<ServerSocket>` | ⛔ | Accept inbound TCP. `host` pins to one of this node's tailnet IPs. | `final srv = await tsnet.tcp.bind(1234);` |

## `tls`

TLS-terminated listener with a cert auto-provisioned by the control
plane. Handlers see plaintext bytes — TLS is terminated server-side.

**Completed in:** Phase 5 (`bind`) + Phase 4 (`domains` preflight).
**Requires:** MagicDNS **and** HTTPS enabled on the tailnet by the
operator. Not covered by the Headscale CI — live-Tailscale test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `tls.bind(port)` → `Future<SecureServerSocket>` | ⛔ | TLS-terminated listener with auto-cert. | `final srv = await tsnet.tls.bind(443);` |
| `tls.domains()` → `Future<List<String>>` | ⛔ | Cert SANs; preflight for `bind`. Empty = HTTPS disabled. | `final sans = await tsnet.tls.domains();` |

## `udp`

UDP datagram sockets over the tailnet. Unlike TCP, `host` is required
— UDP binds to a specific tailnet IP on this node (not `0.0.0.0`).
Grab one from `status().ipv4`.

**Completed in:** Phase 5.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `udp.bind(host, port)` → `Future<RawDatagramSocket>` | ⛔ | UDP listener on a tailnet IP of this node. | `final sock = await tsnet.udp.bind(ip, 4000);` |

## `funnel`

Public-internet HTTPS via Tailscale Funnel: the node is reachable from
the open internet at its Funnel hostname, with edge TLS termination.
The Funnel edge attaches `publicSrc` + `sni` metadata to each accepted
socket; read it via the `Socket.funnel` extension — this lets `bind`
return a standard `SecureServerSocket` instead of a `dart:io` subclass.

**Completed in:** Phase 5. **Requires:** operator has enabled Funnel
in ACLs for this node and an allowed Funnel port (443, 8443, 10000).
Headscale doesn't support Funnel; live-Tailscale test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `funnel.bind(port, {funnelOnly})` → `Future<SecureServerSocket>` | ⛔ | Public-internet TLS listener. `funnelOnly: true` rejects same-tailnet clients. | `final srv = await tsnet.funnel.bind(443);` |
| `FunnelMetadata` value type (`publicSrc`, `sni`) | ✅ | Metadata the Funnel edge attached to a socket. | `const FunnelMetadata(publicSrc: ...);` |
| `Socket.funnel` extension getter | ✅ | Read `FunnelMetadata` off an accepted socket; null if not from Funnel. | `final meta = conn.funnel;` |

## `taildrop`

Peer-to-peer file transfer ("Taildrop") over the tailnet. Sends go
directly between nodes with no intermediary — good fit for
mobile-to-desktop sync, collab tools, anywhere you'd otherwise stand up
a file server. Byte streams use `Stream<Uint8List>` throughout so
producer/consumer can pipe without intermediate buffering.

**Completed in:** Phase 8. **Depends on:** Phase 3 loopback bridge.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `taildrop.targets()` → `Future<List<FileTarget>>` | ⛔ | Peers eligible to receive files right now. | `final ts = await tsnet.taildrop.targets();` |
| `taildrop.push({target, name, data, size?})` | ⛔ | Stream a file to a peer. `size` enables receiver progress reporting. | `await tsnet.taildrop.push(target: t, name: 'x', data: bytes);` |
| `taildrop.waitingFiles()` → `Future<List<WaitingFile>>` | ⛔ | Received files not yet picked up. | `final files = await tsnet.taildrop.waitingFiles();` |
| `taildrop.awaitWaitingFiles({timeout})` | ⛔ | Block until at least one file arrives or timeout fires. | `await tsnet.taildrop.awaitWaitingFiles(timeout: ...);` |
| `taildrop.openRead(name)` → `Stream<Uint8List>` | ⛔ | Byte-stream a received file. Caller owns persistence. | `tsnet.taildrop.openRead('x').pipe(sink);` |
| `taildrop.delete(name)` | ⛔ | Discard a received file without reading. | `await tsnet.taildrop.delete('x');` |
| `taildrop.onWaitingFile` → `Stream<WaitingFile>` | ⛔ | Reactive: emits each arriving file. | `tsnet.taildrop.onWaitingFile.listen(save);` |
| `FileTarget` value type | ✅ | Peer identity (nodeId, hostname, userLoginName). | `target.hostname == 'laptop'` |
| `WaitingFile` value type | ✅ | Name + size of a received file. | `file.size > 0` |

## `serve`

Programmatic access to what `tailscale serve` / `tailscale funnel` do
on the CLI: HTTP routing and public-internet publishing. `ServeConfig`
carries an opaque `etag` for optimistic concurrency — if another
writer lands first, `setConfig` throws `TailscaleServeException` with
`TailscaleErrorCode.conflict`.

**Completed in:** Phase 9. **Depends on:** Phase 2 (value types).
**Also:** Phase 9 bumps the `tailscale.com` Go module pin to pick up
`Services` / `AllowFunnel` / `Foreground` / `ListenService`. Headscale
doesn't support Serve; live-Tailscale test only.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `serve.getConfig()` → `Future<ServeConfig>` | ⛔ | Current serve/funnel config for this node. | `final cfg = await tsnet.serve.getConfig();` |
| `serve.setConfig(ServeConfig)` | ⛔ | Replace atomically; throws on ETag mismatch. | `await tsnet.serve.setConfig(updated);` |
| `ServeConfig` value type (with `etag`) | ✅ | Immutable config object; handler modeling lands in Phase 9. | `const ServeConfig(etag: 'v1');` |

## `exitNode`

Route all outbound traffic from this node through a peer (VPN-style).
Use `use(peer)` when you have a `PeerStatus` in hand, `useById(id)`
when only the stable ID is durable (persisted across sessions), or
`useAuto()` to let the control plane pick by latency and re-pick on
changes.

**Completed in:** Phase 6.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `exitNode.current()` → `Future<PeerStatus?>` | ⛔ | Peer currently used as exit, or null. | `final cur = await tsnet.exitNode.current();` |
| `exitNode.suggest()` → `Future<PeerStatus?>` | ⛔ | Control-plane-recommended exit (latency-based). | `final s = await tsnet.exitNode.suggest();` |
| `exitNode.use(PeerStatus)` | ⛔ | Route through this peer. Type-safe. | `await tsnet.exitNode.use(peer);` |
| `exitNode.useById(stableNodeId)` | ⛔ | Escape hatch when only the stable ID is available. | `await tsnet.exitNode.useById('nAbCd');` |
| `exitNode.useAuto()` | ⛔ | `AutoExitNode` mode — control plane picks and re-picks. | `await tsnet.exitNode.useAuto();` |
| `exitNode.clear()` | ⛔ | Stop routing through an exit node. | `await tsnet.exitNode.clear();` |
| `exitNode.onCurrentChange` → `Stream<PeerStatus?>` | ⛔ | React to changes (incl. external, from another signed-in device). | `tsnet.exitNode.onCurrentChange.listen(update);` |

## `profiles`

Multi-account / multi-tailnet: one device, several identities. Useful
for a single app operating in both a personal and a work tailnet, or
dev vs prod. `switchTo` accepts a `LoginProfile` (type-safe) or use
`switchToId` when you've persisted only the ID.

**Completed in:** Phase 7.

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

**Completed in:** Phase 6.

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
| `diag.ping(ip, {timeout, type})` → `Future<PingResult>` | ⛔ | RTT + direct-vs-DERP diagnostic. Accepts MagicDNS names. | `final r = await tsnet.diag.ping('100.64.0.5');` |
| `diag.metrics()` → `Future<String>` | ⛔ | Prometheus-format metrics snapshot. | `print(await tsnet.diag.metrics());` |
| `diag.derpMap()` → `Future<DERPMap>` | ⛔ | Current DERP relay map. | `final m = await tsnet.diag.derpMap();` |
| `diag.checkUpdate()` → `Future<ClientVersion?>` | ⛔ | Latest version if newer than embedded, else null. | `final v = await tsnet.diag.checkUpdate();` |
| `PingResult`, `DERPMap`, `DERPRegion`, `DERPNode`, `ClientVersion` value types | ✅ | Immutable returns with `==` / `hashCode`. | `ping.direct ? ping.latency : ping.derpRegion` |

## `whois` (top-level)

Resolve a tailnet IP to peer identity (node ID, hostname, owner login,
ACL tags). Lives flat on `Tailscale` rather than under a namespace
because it's a single cross-cutting utility — commonly paired with
`tcp.bind` to authorize inbound connections by tag.

**Completed in:** Phase 4.

| API | Status | Description | Example |
| --- | ------ | ----------- | ------- |
| `whois(ip)` → `Future<PeerIdentity?>` | ⛔ | Identity by tailnet IP; null if not known. | `final id = await tsnet.whois(conn.remoteAddress.address);` |
| `PeerIdentity` value type | ✅ | `nodeId`, `hostName`, `userLoginName`, `tags`, `tailscaleIPs`. | `id.tags.contains('tag:trusted')` |

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
| `TailscaleListenException` | ✅ | `http.expose`. | `on TailscaleListenException catch (_) { ... }` |
| `TailscaleStatusException` | ✅ | `status()`. | `on TailscaleStatusException catch (_) { ... }` |
| `TailscaleLogoutException` | ✅ | `logout()`. | `on TailscaleLogoutException catch (_) { ... }` |
| `TailscaleTaildropException` | ✅ | `taildrop.*`. | `on TailscaleTaildropException catch (_) { ... }` |
| `TailscaleServeException` | ✅ | `serve.*` incl. ETag conflicts. | `on TailscaleServeException catch (e) { ... }` |
| `TailscalePrefsException` | ✅ | `prefs.*`. | `on TailscalePrefsException catch (_) { ... }` |
| `TailscaleProfilesException` | ✅ | `profiles.*`. | `on TailscaleProfilesException catch (_) { ... }` |
| `TailscaleExitNodeException` | ✅ | `exitNode.*`. | `on TailscaleExitNodeException catch (_) { ... }` |
| `TailscaleDiagException` | ✅ | `diag.*`. | `on TailscaleDiagException catch (_) { ... }` |
| `TailscaleRuntimeError` (not `Exception`) | ✅ | Async errors pushed from Go via `onError`. | `tsnet.onError.listen((e) => report(e));` |
