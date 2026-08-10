import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'ffi_bindings.dart' as native;

/// Factory that wraps a native error-response message with the right
/// operation-specific exception subtype. `code` + `statusCode` plumb
/// through from the Go-side error classification so callers can
/// pattern-match on [TailscaleErrorCode].
typedef NativeEnvelopeErrorFactory =
    TailscaleException Function(
      String message, {
      TailscaleErrorCode code,
      int? statusCode,
    });

/// Maps the stable native error vocabulary onto Dart's public error enum.
///
/// Kept outside the worker library because a few synchronous FFI capabilities,
/// such as the generation-bound HTTP client, decode the same envelope.
TailscaleErrorCode parseNativeErrorCode(String? raw) => switch (raw) {
  'lifecycleBusy' => TailscaleErrorCode.lifecycleBusy,
  'runtimeCleanupFailed' => TailscaleErrorCode.runtimeCleanupFailed,
  'configurationMismatch' => TailscaleErrorCode.configurationMismatch,
  'staleRuntime' => TailscaleErrorCode.staleRuntime,
  'dataPlaneNotReady' => TailscaleErrorCode.dataPlaneNotReady,
  'publicationBootstrapFailure' =>
    TailscaleErrorCode.publicationBootstrapFailure,
  'serveConfigConflict' => TailscaleErrorCode.serveConfigConflict,
  'publicationNotApplied' => TailscaleErrorCode.publicationNotApplied,
  'publicationCommitIndeterminate' =>
    TailscaleErrorCode.publicationCommitIndeterminate,
  'startupAbandoned' => TailscaleErrorCode.startupAbandoned,
  'stateLeaseBusy' => TailscaleErrorCode.stateLeaseBusy,
  'invalidStateKey' => TailscaleErrorCode.invalidStateKey,
  'missingStateKey' => TailscaleErrorCode.missingStateKey,
  'orphanedStateKey' => TailscaleErrorCode.orphanedStateKey,
  'localResetIncomplete' => TailscaleErrorCode.localResetIncomplete,
  'conflictingStateFormats' => TailscaleErrorCode.conflictingStateFormats,
  'legacyStateUnsupported' => TailscaleErrorCode.legacyStateUnsupported,
  'unexpectedStateResidue' => TailscaleErrorCode.unexpectedStateResidue,
  'atomicPersistenceFailure' => TailscaleErrorCode.atomicPersistenceFailure,
  'stateAuthenticationFailed' => TailscaleErrorCode.stateAuthenticationFailed,
  'unsupportedStateFormat' => TailscaleErrorCode.unsupportedStateFormat,
  'invalidStateFormat' => TailscaleErrorCode.invalidStateFormat,
  'startupTimeout' => TailscaleErrorCode.startupTimeout,
  'logoutIndeterminate' => TailscaleErrorCode.logoutIndeterminate,
  'workerTerminated' => TailscaleErrorCode.workerTerminated,
  'notFound' => TailscaleErrorCode.notFound,
  'forbidden' => TailscaleErrorCode.forbidden,
  'conflict' => TailscaleErrorCode.conflict,
  'preconditionFailed' => TailscaleErrorCode.preconditionFailed,
  'featureDisabled' => TailscaleErrorCode.featureDisabled,
  _ => TailscaleErrorCode.unknown,
};

/// Invokes [fn], frees the Go-allocated response buffer, and decodes its JSON
/// envelope.
///
/// When [onError] is supplied and the decoded envelope is a map carrying an
/// `error` key, the message is thrown through [onError] with the code mapped
/// by [parseNativeErrorCode] — the single wire vocabulary — plus any
/// `statusCode`. Callers that interpret the error field themselves omit
/// [onError]. Usable on any isolate; the worker helpers and the synchronous
/// caller-isolate FFI capabilities share this decode. [free] is a test seam
/// over [native.duneFree].
dynamic decodeNativeEnvelope(
  ffi.Pointer<Utf8> Function() fn, {
  NativeEnvelopeErrorFactory? onError,
  void Function(ffi.Pointer<Utf8> pointer)? free,
}) {
  final pointer = fn();
  late final String json;
  // Free the Go-allocated buffer even if decoding throws — `toDartString`
  // rejects malformed UTF-8, and Go error strings can carry raw
  // remote-supplied bytes, so without the finally a bad response would leak
  // native memory.
  try {
    json = pointer.toDartString();
  } finally {
    (free ?? native.duneFree)(pointer);
  }
  final decoded = jsonDecode(json);
  if (onError != null && decoded is Map<String, dynamic>) {
    final error = decoded['error'] as String?;
    if (error != null) {
      throw onError(
        error,
        code: parseNativeErrorCode(decoded['code'] as String?),
        statusCode: decoded['statusCode'] as int?,
      );
    }
  }
  return decoded;
}
