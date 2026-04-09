/// Native FFI bindings for the tailscale Go library.
///
/// **This is an internal implementation file.** Do not import directly.
/// Use `package:tailscale/tailscale.dart` instead.
///
/// These functions map 1:1 to the C exports in go/cmd/dylib/main.go.
/// The @DefaultAsset annotation tells the Dart FFI system which native
/// asset to load — matched by the build hook's CodeAsset registration.
///
/// All functions can be called from any isolate in the process.
/// Pointers returned by functions marked with "free with [duneFree]"
/// MUST be freed — failure to do so leaks native memory.
@ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Initializes the Tailscale node and starts the local HTTP proxy.
/// Returns a JSON string: {"port": N} on success, {"error": "..."} on failure.
/// The returned pointer is allocated with C.CString (malloc) — free with [duneFree].
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

/// Returns a JSON array of online peer IPv4 addresses: ["100.64.0.1", ...].
/// Returns "[]" if the server is not running.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneGetPeers')
external ffi.Pointer<Utf8> duneGetPeers();

/// Returns the local Tailscale IPv4 address, or "" if unavailable.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneGetLocalIP')
external ffi.Pointer<Utf8> duneGetLocalIP();

/// Checks if the state directory contains a valid machine key.
/// Returns 1 if provisioned, 0 otherwise.
@ffi.Native<ffi.Int32 Function(ffi.Pointer<Utf8>)>(symbol: 'DuneHasState')
external int duneHasState(ffi.Pointer<Utf8> stateDir);

/// Stops the server and removes the state directory.
@ffi.Native<ffi.Void Function(ffi.Pointer<Utf8>)>(symbol: 'DuneLogout')
external void duneLogout(ffi.Pointer<Utf8> stateDir);

/// Stops the server, preserving state for reconnection.
@ffi.Native<ffi.Void Function()>(symbol: 'DuneStop')
external void duneStop();

/// Starts a reverse proxy: listens on tailnet port 80, forwards to local [port].
@ffi.Native<ffi.Void Function(ffi.Int32)>(symbol: 'DuneListen')
external void duneListen(int port);

/// Returns the full Tailscale status as a JSON string.
/// Returns "{}" if the server is not running.
@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'DuneStatus')
external ffi.Pointer<Utf8> duneStatus();

/// Frees a pointer allocated by the Go layer (C.CString / malloc).
/// Must be used to free pointers returned by [duneStart], [duneGetPeers],
/// [duneGetLocalIP], and [duneStatus].
@ffi.Native<ffi.Void Function(ffi.Pointer<Utf8>)>(symbol: 'DuneFree')
external void duneFree(ffi.Pointer<Utf8> ptr);

/// Sets the Go log level. 0=silent (default), 1=errors only, 2=info+errors.
@ffi.Native<ffi.Void Function(ffi.Int32)>(symbol: 'DuneSetLogLevel')
external void duneSetLogLevel(int level);
