/// Native FFI bindings for the tailscale Go library.
///
/// **This is an internal implementation file.** Do not import directly.
/// Use `package:tailscale/tailscale.dart` instead.
@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Starts the Tailscale node.
/// Returns JSON:
///   {"ok": true} on success
///   {"error": "..."} on failure.
@ffi.Native<
  ffi.Pointer<Utf8> Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
  )
>(symbol: 'DuneStart')
external ffi.Pointer<Utf8> duneStart(
  ffi.Pointer<Utf8> hostname,
  ffi.Pointer<Utf8> authKey,
  ffi.Pointer<Utf8> controlURL,
  ffi.Pointer<Utf8> stateDir,
);

/// Starts one outgoing tailnet HTTP request.
///
/// Returns JSON:
///   {"requestBodyFd": N|-1, "responseBodyFd": N} on success
///   {"error": "..."} on failure.
@ffi.Native<
  ffi.Pointer<Utf8> Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Int64,
    ffi.Int32,
    ffi.Int32,
  )
>(symbol: 'DuneHttpStart')
external ffi.Pointer<Utf8> duneHttpStart(
  ffi.Pointer<Utf8> method,
  ffi.Pointer<Utf8> url,
  ffi.Pointer<Utf8> headersJson,
  int contentLength,
  int followRedirects,
  int maxRedirects,
);

/// Provides a host network-interface snapshot to the native runtime.
///
/// This is currently used on Android before startup because Go's standard
/// netlink-based interface discovery can be denied by the app sandbox.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneSetNetworkInterfaces',
)
external ffi.Pointer<Utf8> duneSetNetworkInterfaces(ffi.Pointer<Utf8> snapshot);

/// Starts an fd-backed inbound HTTP binding.
/// Returns JSON:
///   {"bindingId": N, "tailnetAddress": "...", "tailnetPort": N} on success
///   {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(symbol: 'DuneHttpBind')
external ffi.Pointer<Utf8> duneHttpBind(int tailnetPort);

/// Blocks until an inbound HTTP binding accepts one request or closes.
///
/// Returns JSON:
///   {"requestBodyFd": N, "responseBodyFd": N, ...metadata} on success
///   {"closed": true} when the binding is closed
///   {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int64)>(symbol: 'DuneHttpAccept')
external ffi.Pointer<Utf8> duneHttpAccept(int bindingId);

/// Closes an HTTP binding.
@ffi.Native<ffi.Void Function(ffi.Int64)>(symbol: 'DuneHttpCloseBinding')
external void duneHttpCloseBinding(int bindingId);

/// Opens an outbound TCP connection and returns a POSIX fd for the Dart side.
///
/// Returns JSON:
///   {"fd": N, "localAddress": "...", "localPort": N,
///    "remoteAddress": "...", "remotePort": N} on success.
///   {"error": "..."} on failure.
///
/// POSIX-only backend primitive. Unsupported platforms fail explicitly.
@ffi.Native<
  ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Int64)
>(symbol: 'DuneTcpDialFd')
external ffi.Pointer<Utf8> duneTcpDialFd(
  ffi.Pointer<Utf8> host,
  int port,
  int timeoutMillis,
);

/// Starts a POSIX fd-backed TCP listener.
///
/// Returns JSON:
///   {"listenerId": N, "localAddress": "...", "localPort": N} on success.
///   {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32, ffi.Pointer<Utf8>)>(
  symbol: 'DuneTcpListenFd',
)
external ffi.Pointer<Utf8> duneTcpListenFd(
  int tailnetPort,
  ffi.Pointer<Utf8> tailnetHost,
);

/// Starts a POSIX fd-backed TLS listener.
///
/// Returns JSON:
///   {"listenerId": N, "localAddress": "...", "localPort": N} on success.
///   {"error": "..."} on failure.
///
/// Accepted connections are still retrieved through [duneTcpAcceptFd] because
/// the native runtime terminates TLS and exposes the resulting plaintext stream
/// as the same local fd capability used by TCP listeners.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32, ffi.Pointer<Utf8>)>(
  symbol: 'DuneTlsListenFd',
)
external ffi.Pointer<Utf8> duneTlsListenFd(
  int tailnetPort,
  ffi.Pointer<Utf8> tailnetHost,
);

/// Blocks until a fd-backed listener accepts one connection or closes.
///
/// Returns JSON:
///   {"fd": N, "localAddress": "...", "localPort": N,
///    "remoteAddress": "...", "remotePort": N} on accepted connection.
///   {"closed": true} when the listener is closed.
///   {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int64)>(symbol: 'DuneTcpAcceptFd')
external ffi.Pointer<Utf8> duneTcpAcceptFd(int listenerId);

/// Closes a POSIX fd-backed TCP listener.
@ffi.Native<ffi.Void Function(ffi.Int64)>(symbol: 'DuneTcpCloseFdListener')
external void duneTcpCloseFdListener(int listenerId);

/// Starts a POSIX fd-backed UDP datagram binding.
///
/// Returns JSON:
///   {"fd": N, "localAddress": "...", "localPort": N} on success.
///   {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int32)>(
  symbol: 'DuneUdpBindFd',
)
external ffi.Pointer<Utf8> duneUdpBindFd(ffi.Pointer<Utf8> host, int port);

/// Creates one native fd reactor poller and returns an opaque handle, or -1 on
/// failure.
@ffi.Native<ffi.Int64 Function()>(symbol: 'DuneReactorCreate')
external int duneReactorCreate();

/// Closes a native fd reactor poller.
@ffi.Native<ffi.Int32 Function(ffi.Int64)>(symbol: 'DuneReactorClose')
external int duneReactorClose(int handle);

/// Wakes a native fd reactor poller blocked in wait.
@ffi.Native<ffi.Int32 Function(ffi.Int64)>(symbol: 'DuneReactorWake')
external int duneReactorWake(int handle);

/// Registers one fd with the native fd reactor poller.
@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Int32, ffi.Int64, ffi.Int32)>(
  symbol: 'DuneReactorRegister',
)
external int duneReactorRegister(
  int handle,
  int fd,
  int transportId,
  int events,
);

/// Updates one fd's read/write interest in the native fd reactor poller.
@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Int32, ffi.Int64, ffi.Int32)>(
  symbol: 'DuneReactorUpdate',
)
external int duneReactorUpdate(int handle, int fd, int transportId, int events);

/// Unregisters one fd from the native fd reactor poller.
@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Int32)>(
  symbol: 'DuneReactorUnregister',
)
external int duneReactorUnregister(int handle, int fd);

/// Blocks until native fd reactor events are available.
@ffi.Native<
  ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32)
>(symbol: 'DuneReactorWait')
external int duneReactorWait(
  int handle,
  ffi.Pointer<ffi.Void> events,
  int maxEvents,
  int timeoutMillis,
);

/// Resolves a tailnet IP to its node identity via LocalAPI.
///
/// Returns JSON:
///   {"found": true, "nodeId": "...", "hostName": "...",
///    "userLoginName": "...", "tags": [...], "tailscaleIPs": [...]}
///     on success.
///   {"found": false} if the IP isn't known on this tailnet.
///   {"error": "..."} on other failures.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(symbol: 'DuneWhoIs')
external ffi.Pointer<Utf8> duneWhoIs(ffi.Pointer<Utf8> ip);

/// Returns the auto-provisioned TLS cert's Subject Alternative Names.
///
/// Returns JSON `{"domains": [...]}` on success, `{"error": ...}` on
/// failure. Empty domains array means MagicDNS or HTTPS is disabled
/// on the tailnet.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneTlsDomains')
external ffi.Pointer<Utf8> duneTlsDomains();

/// Tailscale-level ping to a tailnet node.
///
/// `timeoutMillis <= 0` means no timeout. `pingType` is one of
/// "disco" (default), "tsmp", "icmp".
///
/// Returns JSON:
///   {"latencyMicros": N, "path": "direct"|"derp"|"unknown",
///    "derpRegion": "..."?}
///     on success.
///   {"error": "..."} on failure.
@ffi.Native<
  ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Pointer<Utf8>)
>(symbol: 'DuneDiagPing')
external ffi.Pointer<Utf8> duneDiagPing(
  ffi.Pointer<Utf8> ip,
  int timeoutMillis,
  ffi.Pointer<Utf8> pingType,
);

/// Prometheus-format user metrics. Returns JSON
/// `{"metrics": "..."}` on success, `{"error": "..."}` on failure.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneDiagMetrics')
external ffi.Pointer<Utf8> duneDiagMetrics();

/// Current DERP relay map. Returns JSON
/// `{"regions": {...}, "omitDefaultRegions": bool}` on success,
/// `{"error": "..."}` on failure.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneDiagDERPMap')
external ffi.Pointer<Utf8> duneDiagDERPMap();

/// Control-plane update check. Returns JSON
/// `{"available": false}` when on latest, or
/// `{"available": true, "latestVersion": "...", "urgentSecurityUpdate": bool, "notifyText": "..."?}`
/// when an update is available; `{"error": "..."}` on failure.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneDiagCheckUpdate')
external ffi.Pointer<Utf8> duneDiagCheckUpdate();

/// Returns 1 if the state directory has a valid machine key, 0 otherwise.
@ffi.Native<ffi.Int32 Function(ffi.Pointer<Utf8>)>(symbol: 'DuneHasState')
external int duneHasState(ffi.Pointer<Utf8> stateDir);

/// Stops the server and removes the state directory.
/// Returns JSON: {"ok": true} on success, {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(symbol: 'DuneLogout')
external ffi.Pointer<Utf8> duneLogout(ffi.Pointer<Utf8> stateDir);

/// Stops the server, preserving state.
@ffi.Native<ffi.Void Function()>(symbol: 'DuneStop')
external void duneStop();

/// Returns the local-node Tailscale status as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneStatus')
external ffi.Pointer<Utf8> duneStatus();

/// Returns the current node list as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DunePeers')
external ffi.Pointer<Utf8> dunePeers();

/// Returns the current node preferences subset as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DunePrefsGet')
external ffi.Pointer<Utf8> dunePrefsGet();

/// Applies a JSON-encoded PrefsUpdate and returns the updated prefs JSON.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DunePrefsUpdate',
)
external ffi.Pointer<Utf8> dunePrefsUpdate(ffi.Pointer<Utf8> updateJson);

/// Returns LocalAPI's suggested exit-node stable ID as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneExitNodeSuggest')
external ffi.Pointer<Utf8> duneExitNodeSuggest();

/// Enables AutoExitNode=any and returns the updated prefs JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneExitNodeUseAuto')
external ffi.Pointer<Utf8> duneExitNodeUseAuto();

/// Publishes a local HTTP service through Tailscale Serve/Funnel.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneServeForward',
)
external ffi.Pointer<Utf8> duneServeForward(ffi.Pointer<Utf8> payloadJson);

/// Removes a Tailscale Serve/Funnel publication.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneServeClear',
)
external ffi.Pointer<Utf8> duneServeClear(ffi.Pointer<Utf8> payloadJson);

/// Frees a pointer allocated by the Go layer.
@ffi.Native<ffi.Void Function(ffi.Pointer<Utf8>)>(symbol: 'DuneFree')
external void duneFree(ffi.Pointer<Utf8> ptr);

/// Sets the Go log level. 0=silent (default), 1=errors, 2=info.
@ffi.Native<ffi.Void Function(ffi.Int32)>(symbol: 'DuneSetLogLevel')
external void duneSetLogLevel(int level);

/// Initializes the Dart DL API for native push notifications.
/// Must be called once with NativeApi.initializeApiDLData.
/// Returns 0 on success, -1 on version mismatch.
@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(symbol: 'DuneInitDartAPI')
external int duneInitDartAPI(ffi.Pointer<ffi.Void> data);

/// Sets the Dart ReceivePort ID for receiving push notifications from Go.
@ffi.Native<ffi.Void Function(ffi.Int64)>(symbol: 'DuneSetDartPort')
external void duneSetDartPort(int portId);

/// Starts watching tsnet state changes and posting to the Dart port.
/// Must be called after DuneStart and DuneSetDartPort.
@ffi.Native<ffi.Void Function()>(symbol: 'DuneStartWatch')
external void duneStartWatch();

/// Stops the state watcher.
@ffi.Native<ffi.Void Function()>(symbol: 'DuneStopWatch')
external void duneStopWatch();
