/// Native FFI bindings for the tailscale Go library.
///
/// **This is an internal implementation file.** Do not import directly.
/// Use `package:tailscale/tailscale.dart` instead.
@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Starts the Tailscale node.
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

/// Starts the reverse proxy (tailnet:tailnetPort → localhost:localPort).
/// If localPort is 0, allocates an ephemeral port.
/// Returns JSON: {"listenPort": N} on success, {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32, ffi.Int32)>(
  symbol: 'DuneListen',
)
external ffi.Pointer<Utf8> duneListen(int localPort, int tailnetPort);

/// Resolves a tailnet IP to its peer identity via LocalAPI.
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

/// Tailscale-level ping to a tailnet peer.
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
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Pointer<Utf8>,
    )>(
  symbol: 'DuneDiagPing',
)
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

/// Returns the current peer list as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DunePeers')
external ffi.Pointer<Utf8> dunePeers();

/// Attaches the canonical internal transport session to a caller-provided
/// carrier endpoint. Accepts JSON and returns JSON.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneAttachTransport',
)
external ffi.Pointer<Utf8> duneAttachTransport(ffi.Pointer<Utf8> requestJson);

/// Starts a raw TCP listener on the tailnet.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(symbol: 'DuneTCPBind')
external ffi.Pointer<Utf8> duneTcpBind(int port);

/// Stops a raw TCP listener on the tailnet.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(symbol: 'DuneTCPUnbind')
external ffi.Pointer<Utf8> duneTcpUnbind(int port);

/// Opens a raw TCP connection to a tailnet peer and returns a stream id.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int32)>(
  symbol: 'DuneTCPDial',
)
external ffi.Pointer<Utf8> duneTcpDial(ffi.Pointer<Utf8> host, int port);

/// Starts a raw UDP listener on the tailnet and returns a binding id.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(symbol: 'DuneUDPBind')
external ffi.Pointer<Utf8> duneUdpBind(int port);

/// Starts a streamed Go-backed HTTP request and returns JSON.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneHTTPStartRequest',
)
external ffi.Pointer<Utf8> duneHttpStartRequest(
  ffi.Pointer<Utf8> requestJson,
);

/// Sends one buffered body chunk for an in-flight Go-backed HTTP request.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneHTTPWriteBodyChunk',
)
external ffi.Pointer<Utf8> duneHttpWriteBodyChunk(
  ffi.Pointer<Utf8> requestJson,
);

/// Closes the request body stream for an in-flight Go-backed HTTP request.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneHTTPCloseRequestBody',
)
external ffi.Pointer<Utf8> duneHttpCloseRequestBody(
  ffi.Pointer<Utf8> requestJson,
);

/// Cancels an in-flight Go-backed HTTP request.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>(
  symbol: 'DuneHTTPCancelRequest',
)
external ffi.Pointer<Utf8> duneHttpCancelRequest(
  ffi.Pointer<Utf8> requestJson,
);

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
