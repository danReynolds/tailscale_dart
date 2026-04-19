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

/// Base class for operation-specific failures such as `up()` or `listen()`.
class TailscaleOperationException extends TailscaleException {
  const TailscaleOperationException(
    this.operation,
    String message, {
    super.cause,
  }) : super(message);

  /// Public API operation that failed.
  final String operation;

  @override
  String toString() {
    if (cause == null) {
      return '$runtimeType($operation): $message';
    }
    return '$runtimeType($operation): $message (cause: $cause)';
  }
}

/// Thrown when `up()` fails before the node reaches Running.
final class TailscaleUpException extends TailscaleOperationException {
  const TailscaleUpException(String message, {Object? cause})
      : super('up', message, cause: cause);
}

/// Thrown when `listen()` fails to expose a local HTTP server.
final class TailscaleListenException extends TailscaleOperationException {
  const TailscaleListenException(String message, {Object? cause})
      : super('listen', message, cause: cause);
}

/// Thrown when `status()` fails to decode or fetch native status.
final class TailscaleStatusException extends TailscaleOperationException {
  const TailscaleStatusException(String message, {Object? cause})
      : super('status', message, cause: cause);
}

/// Thrown when `logout()` fails to clear persisted state.
final class TailscaleLogoutException extends TailscaleOperationException {
  const TailscaleLogoutException(String message, {Object? cause})
      : super('logout', message, cause: cause);
}

/// High-level category for asynchronous runtime errors pushed from Go.
enum TailscaleRuntimeErrorCode { localClient, watcher, node, unknown }

TailscaleRuntimeErrorCode _parseRuntimeErrorCode(String? value) =>
    switch (value) {
      'localClient' => TailscaleRuntimeErrorCode.localClient,
      'watcher' => TailscaleRuntimeErrorCode.watcher,
      'node' => TailscaleRuntimeErrorCode.node,
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
  String toString() => '$runtimeType(${code.name}): $message';
}
