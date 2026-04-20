/// Native FFI bindings for the tailscale Go library.
///
/// **This is an internal implementation file.** Do not import directly.
/// Use `package:tailscale/tailscale.dart` instead.
@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Starts the Tailscale node and outgoing HTTP proxy.
/// Returns JSON:
///   {"proxyPort": N, "proxyAuthToken": "..."} on success
///   {"error": "..."} on failure.
@ffi.Native<
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
    )>(symbol: 'DuneStart')
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

/// Opens an outbound TCP connection to a tailnet peer and sets up a
/// one-shot loopback bridge for the Dart side.
///
/// Returns JSON:
///   {"loopbackPort": N, "token": "..."} on success.
///   {"error": "..."} on failure.
///
/// Dart connects to `127.0.0.1:loopbackPort` and writes `token` as
/// the first bytes on the wire. After that the socket is a
/// transparent pipe to the peer.
///
/// `timeoutMillis` is the total `tcp.dial` bridge budget; 0 means no
/// timeout.
@ffi.Native<
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Int64)>(
  symbol: 'DuneTcpDial',
)
external ffi.Pointer<Utf8> duneTcpDial(
  ffi.Pointer<Utf8> host,
  int port,
  int timeoutMillis,
);

/// Starts an inbound TCP bridge: this node's tsnet.Server listens on
/// `tailnetPort` (optionally pinned to `tailnetHost`), and every
/// accepted tailnet conn is forwarded to the Dart-owned loopback
/// listener on `127.0.0.1:loopbackPort`.
///
/// Pass `tailnetPort = 0` to request an ephemeral tailnet port; the
/// assigned port comes back in the response JSON.
///
/// Returns JSON:
///   {"tailnetPort": N} on success (`N` is the actual bound port —
///   useful when `0` was passed).
///   {"error": "..."} on failure.
///
/// Pass empty string for `tailnetHost` to accept on all of this
/// node's tailnet IPs.
@ffi.Native<
    ffi.Pointer<Utf8> Function(ffi.Int32, ffi.Pointer<Utf8>, ffi.Int32)>(
  symbol: 'DuneTcpBind',
)
external ffi.Pointer<Utf8> duneTcpBind(
  int tailnetPort,
  ffi.Pointer<Utf8> tailnetHost,
  int loopbackPort,
);

/// Tears down the inbound TCP bridge registered against
/// `loopbackPort`. Idempotent — unknown ports are a no-op.
@ffi.Native<ffi.Void Function(ffi.Int32)>(symbol: 'DuneTcpUnbind')
external void duneTcpUnbind(int loopbackPort);

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
