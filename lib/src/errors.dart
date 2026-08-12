/// Library-level exception types for embedded Tailscale operations.
///
/// - [TailscaleUsageException] — API used in an invalid lifecycle state.
/// - [TailscaleOperationException] (+ subclasses) — operation-specific
///   failures carrying a structured [TailscaleErrorCode].
/// - [TailscaleRuntimeError] — async background failures pushed from Go.
library;

/// Structured category for operation failures.
///
/// Lets callers branch on common outcomes without string-matching
/// [TailscaleException.message]. Maps to the distinctions the Go
/// [LocalAPI](https://pkg.go.dev/tailscale.com/client/local) surface
/// exposes (e.g. `IsAccessDeniedError`, `IsPreconditionsFailedError`).
enum TailscaleErrorCode {
  /// Another start/stop transition currently owns the process lifecycle.
  lifecycleBusy,

  /// Native teardown or state cleanup failed; restart before further use.
  runtimeCleanupFailed,

  /// Immutable active-runtime configuration differs from the request.
  configurationMismatch,

  /// The operation belongs to a node runtime that has already stopped.
  staleRuntime,

  /// The node has not completed its Running/publication bootstrap gate.
  dataPlaneNotReady,

  /// The mandatory first-Up publication reset failed for this runtime.
  publicationBootstrapFailure,

  /// ServeConfig changed during all bounded mutation attempts.
  serveConfigConflict,

  /// The publication mutation conclusively did not reach ServeConfig.
  publicationNotApplied,

  /// A ServeConfig mutation may have applied before its result was lost.
  publicationCommitIndeterminate,

  /// Native startup was quarantined before it could publish a runtime.
  startupAbandoned,

  /// Another process or isolate owns the persistent StateStore lease.
  stateLeaseBusy,

  /// The persistent StateStore DEK was not exactly 32 raw bytes.
  invalidStateKey,

  /// An encrypted state envelope exists but its Keybay DEK is absent.
  missingStateKey,

  /// Keybay contains a DEK but the corresponding state envelope is absent.
  orphanedStateKey,

  /// A previously authorized local reset has not completed.
  localResetIncomplete,

  /// Legacy plaintext SQLite/FileStore and encrypted artifacts coexist.
  conflictingStateFormats,

  /// A pre-launch plaintext SQLite/FileStore requires explicit local forget.
  legacyStateUnsupported,

  /// The package state subtree contains unrecognized residual files.
  unexpectedStateResidue,

  /// An interrupted atomic envelope write could not be safely recovered.
  atomicPersistenceFailure,

  /// The Keybay key did not authenticate the encrypted envelope.
  stateAuthenticationFailed,

  /// The encrypted envelope uses a newer or unsupported format tuple.
  unsupportedStateFormat,

  /// The encrypted envelope or its security metadata is malformed.
  invalidStateFormat,

  /// The platform keystore is locked or requires unavailable interaction.
  secureStorageLocked,

  /// Keybay cannot safely access its platform-protected container.
  secureStorageUnavailable,

  /// Another live writer currently owns Keybay's mutation lock.
  secureStorageBusy,

  /// The caller deadline expired and the matching runtime was quarantined.
  startupTimeout,

  /// Upstream logout may have completed; local recovery evidence was retained.
  logoutIndeterminate,

  /// The supervised control isolate exited unexpectedly.
  workerTerminated,

  /// Target does not exist (unknown node, waiting file, profile, route...).
  notFound,

  /// Authenticated but the tailnet's
  /// [ACLs](https://tailscale.com/kb/1018/acls) disallow the action.
  forbidden,

  /// Another concurrent writer landed first (ETag / version mismatch).
  conflict,

  /// A required precondition is not met — node not running, tailnet
  /// feature disabled, missing capability, etc.
  preconditionFailed,

  /// The tailnet feature this call depends on is disabled by the
  /// operator (Funnel off,
  /// [MagicDNS](https://tailscale.com/kb/1081/magicdns) off, Taildrop
  /// off, …).
  featureDisabled,

  /// Anything the runtime didn't categorize.
  unknown,
}

/// Stable library-level exception base for embedded Tailscale operations.
sealed class TailscaleException implements Exception {
  const TailscaleException(this.message, {this.cause});

  /// Human-readable error message.
  final String message;

  /// Optional underlying cause from JSON decoding, FFI, or runtime code.
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return '$runtimeType: $message';
    }
    return '$runtimeType: $message (cause: $cause)';
  }
}

/// Thrown when the API is used in an invalid lifecycle state.
final class TailscaleUsageException extends TailscaleException {
  const TailscaleUsageException(super.message, {super.cause});
}

/// Thrown when `Tailscale.init` conflicts with the process-wide state root or
/// logging configuration already frozen by an earlier successful call.
final class TailscaleConfigurationException extends TailscaleException {
  const TailscaleConfigurationException(super.message, {super.cause});
}

/// Base class for operation-specific failures such as `up()` or `listen()`.
///
/// Carries a structured [code] so callers can branch on outcomes without
/// matching [message], plus the HTTP [statusCode] from the local API when
/// the failure originated there (useful when [code] is
/// [TailscaleErrorCode.unknown]).
class TailscaleOperationException extends TailscaleException {
  const TailscaleOperationException(
    this.operation,
    String message, {
    this.code = TailscaleErrorCode.unknown,
    this.statusCode,
    super.cause,
  }) : super(message);

  /// Public API operation that failed.
  final String operation;

  /// Structured failure category.
  final TailscaleErrorCode code;

  /// HTTP status code when the failure came from the local API, else null.
  final int? statusCode;

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType($operation)');
    if (code != TailscaleErrorCode.unknown) {
      buffer.write('[${code.name}]');
    }
    buffer.write(': $message');
    if (cause != null) buffer.write(' (cause: $cause)');
    return buffer.toString();
  }
}

/// Thrown when `up()` fails before the node reaches a stable state.
final class TailscaleUpException extends TailscaleOperationException {
  const TailscaleUpException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('up', message);
}

/// Thrown when an `http.*` call fails — notably `http.bind()` failing
/// to forward tailnet traffic, or `http.client` accessed before `up()`.
final class TailscaleHttpException extends TailscaleOperationException {
  const TailscaleHttpException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('http', message);
}

/// Thrown when a `tcp.*` call fails — tailnet dial refused, no route
/// to node, fd handoff failure, etc.
final class TailscaleTcpException extends TailscaleOperationException {
  const TailscaleTcpException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('tcp', message);
}

/// Thrown when a `udp.*` call fails — tailnet bind failure, invalid endpoint,
/// oversize datagram, fd handoff failure, etc.
final class TailscaleUdpException extends TailscaleOperationException {
  const TailscaleUdpException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('udp', message);
}

/// Thrown when a `tls.*` call fails — certificate-domain discovery,
/// TLS listener setup, or tailnet HTTPS precondition failures.
final class TailscaleTlsException extends TailscaleOperationException {
  const TailscaleTlsException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('tls', message);
}

/// Thrown when `status()` fails to decode or fetch native status.
final class TailscaleStatusException extends TailscaleOperationException {
  const TailscaleStatusException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('status', message);
}

/// Thrown when `logout()` cannot confirm remote revocation or local cleanup.
final class TailscaleLogoutException extends TailscaleOperationException {
  const TailscaleLogoutException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('logout', message);
}

/// Thrown when explicit local identity destruction cannot be completed.
final class TailscaleForgetLocalIdentityException
    extends TailscaleOperationException {
  const TailscaleForgetLocalIdentityException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('forget local identity', message);
}

/// Thrown when a `serve.*` call fails — most notably a conflicting
/// Serve config write or unsupported tailnet publication.
final class TailscaleServeException extends TailscaleOperationException {
  const TailscaleServeException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('serve', message);
}

/// Thrown when a `funnel.*` call fails — most notably missing Funnel policy,
/// unsupported public ports, or tailnet HTTPS preconditions.
final class TailscaleFunnelException extends TailscaleOperationException {
  const TailscaleFunnelException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('funnel', message);
}

/// Thrown when a `prefs.*` call fails.
final class TailscalePrefsException extends TailscaleOperationException {
  const TailscalePrefsException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('prefs', message);
}

/// Thrown when an `exitNode.*` call fails.
final class TailscaleExitNodeException extends TailscaleOperationException {
  const TailscaleExitNodeException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('exitNode', message);
}

/// Thrown when a `diag.*` call fails.
final class TailscaleDiagException extends TailscaleOperationException {
  const TailscaleDiagException(
    String message, {
    super.code,
    super.statusCode,
    super.cause,
  }) : super('diag', message);
}

/// High-level category for asynchronous runtime errors pushed from Go.
enum TailscaleRuntimeErrorCode {
  localClient,
  watcher,
  node,
  worker,

  /// The runtime's mandatory first-Up publication reset failed fatally.
  publicationBootstrapFailure,

  /// A committed publication could not be transferred to an exact Dart
  /// handle, so native quarantined the runtime rather than leave live ingress.
  publicationDeliveryFailure,

  unknown,
}

TailscaleRuntimeErrorCode _parseRuntimeErrorCode(String? value) =>
    switch (value) {
      'localClient' => TailscaleRuntimeErrorCode.localClient,
      'watcher' => TailscaleRuntimeErrorCode.watcher,
      'node' => TailscaleRuntimeErrorCode.node,
      'worker' => TailscaleRuntimeErrorCode.worker,
      'publicationBootstrapFailure' =>
        TailscaleRuntimeErrorCode.publicationBootstrapFailure,
      'publicationDeliveryFailure' =>
        TailscaleRuntimeErrorCode.publicationDeliveryFailure,
      _ => TailscaleRuntimeErrorCode.unknown,
    };

/// Asynchronous background error pushed from the embedded runtime.
final class TailscaleRuntimeError {
  const TailscaleRuntimeError({required this.message, required this.code});

  factory TailscaleRuntimeError.fromPushPayload(Map<String, dynamic> payload) {
    return TailscaleRuntimeError(
      message: payload['error'] as String? ?? 'Unknown error',
      code: _parseRuntimeErrorCode(payload['code'] as String?),
    );
  }

  /// Human-readable error string from the native runtime.
  final String message;

  /// High-level category for the background error.
  final TailscaleRuntimeErrorCode code;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleRuntimeError &&
          message == other.message &&
          code == other.code;

  @override
  int get hashCode => Object.hash(message, code);

  @override
  String toString() => '$runtimeType(${code.name}): $message';
}
