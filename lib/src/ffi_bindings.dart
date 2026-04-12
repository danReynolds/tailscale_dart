/// Native FFI bindings for the tailscale Go library.
///
/// **This is an internal implementation file.** Do not import directly.
/// Use `package:tailscale/tailscale.dart` instead.
@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Starts the Tailscale node and outgoing HTTP proxy.
/// Returns JSON: {"proxyPort": N} on success, {"error": "..."} on failure.
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

/// Starts the reverse proxy (tailnet:80 → localhost:localPort).
/// If localPort is 0, allocates an ephemeral port.
/// Returns JSON: {"listenPort": N} on success, {"error": "..."} on failure.
@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(symbol: 'DuneListen')
external ffi.Pointer<Utf8> duneListen(int localPort);

/// Returns a JSON array of online peer IPv4 addresses.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneGetPeers')
external ffi.Pointer<Utf8> duneGetPeers();

/// Returns the local Tailscale IPv4 address, or "".
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneGetLocalIP')
external ffi.Pointer<Utf8> duneGetLocalIP();

/// Returns 1 if the state directory has a valid machine key, 0 otherwise.
@ffi.Native<ffi.Int32 Function(ffi.Pointer<Utf8>)>(symbol: 'DuneHasState')
external int duneHasState(ffi.Pointer<Utf8> stateDir);

/// Stops the server and removes the state directory.
@ffi.Native<ffi.Void Function(ffi.Pointer<Utf8>)>(symbol: 'DuneLogout')
external void duneLogout(ffi.Pointer<Utf8> stateDir);

/// Stops the server, preserving state.
@ffi.Native<ffi.Void Function()>(symbol: 'DuneStop')
external void duneStop();

/// Returns the full Tailscale status as JSON.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneStatus')
external ffi.Pointer<Utf8> duneStatus();

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
