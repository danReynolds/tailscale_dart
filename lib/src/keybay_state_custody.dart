import 'dart:math';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
import 'package:meta/meta.dart';

import 'errors.dart';

/// Keybay entry containing the installation-level StateStore encryption key.
const String stateStoreDekEntry = 'tailscale/state-store/v1/dek';

/// Non-secret label shown for the DEK in platform credential UIs.
const String stateStoreDekLabel = 'Tailscale node-state encryption key';

/// Fixed binary key size used by the Go encrypted StateStore.
const int stateStoreDekLength = 32;

const String _keybayNamespaceSuffix = '.tailscale';
const int _keybayAppIdLimit = 120;
const int _hostAppIdLimit = _keybayAppIdLimit - _keybayNamespaceSuffix.length;

typedef KeybayStorageFactory = SecretStorage Function({required String appId});

SecretStorage _createKeybayStorage({required String appId}) =>
    SecretStorage(appId: appId);

KeybayStorageFactory? _debugStorageFactory;

/// Installs an isolate-local Keybay backend factory before package
/// initialization.
///
/// This is a test seam only. Production callers always use Keybay's fixed
/// platform policy, while native integration tests use an in-memory backend so
/// headless Linux CI can exercise persistent lifecycle orchestration without
/// pretending it has a desktop credential service.
@visibleForTesting
void debugOverrideKeybayStorageFactory(KeybayStorageFactory? factory) {
  _debugStorageFactory = factory;
}

/// Maps Keybay's platform-specific taxonomy to stable package-level outcomes
/// without exposing backend text as the primary public error message.
@internal
TailscaleOperationException mapKeybayStateCustodyError(
  Object error, {
  required String action,
}) {
  if (error is TailscaleOperationException) return error;
  if (error is KeystoreLocked) {
    return TailscaleOperationException(
      'state custody',
      'Secure storage is locked; unlock it and retry $action.',
      code: TailscaleErrorCode.secureStorageLocked,
      cause: error,
    );
  }
  if (error is StoreBusy) {
    return TailscaleOperationException(
      'state custody',
      'Secure storage is busy; retry $action after the current writer exits.',
      code: TailscaleErrorCode.secureStorageBusy,
      cause: error,
    );
  }
  if (error is SecretStoreException || error is ArgumentError) {
    return TailscaleOperationException(
      'state custody',
      'Secure storage is unavailable; $action could not be completed safely.',
      code: TailscaleErrorCode.secureStorageUnavailable,
      cause: error,
    );
  }
  return TailscaleOperationException(
    'state custody',
    'Secure storage failed unexpectedly while attempting to $action.',
    code: TailscaleErrorCode.secureStorageUnavailable,
    cause: error,
  );
}

/// The frozen, lazy Keybay binding for Tailscale's encrypted StateStore DEK.
///
/// Constructing this object performs no platform storage work. The Keybay
/// backend is resolved only when [createStorage] is called by a later
/// persistent lifecycle operation. Ephemeral runtimes must never call it.
@internal
final class KeybayStateCustodyBinding {
  KeybayStateCustodyBinding({
    required this.hostAppId,
    KeybayStorageFactory? storageFactory,
  }) : keybayNamespace = deriveKeybayAppId(hostAppId),
       _storageFactory =
           storageFactory ?? _debugStorageFactory ?? _createKeybayStorage;

  /// Stable identifier supplied by the embedding application.
  final String hostAppId;

  /// Dedicated Keybay namespace; never shared with the host's other secrets.
  final String keybayNamespace;

  final KeybayStorageFactory _storageFactory;

  /// Resolves the production Keybay container on the calling isolate.
  SecretStorage createStorage() => _storageFactory(appId: keybayNamespace);
}

/// Validates [hostAppId] and derives Tailscale's dedicated Keybay namespace.
///
/// Keybay permits at most 120 characters. The host-identifier budget reserves
/// enough room for the package's `.tailscale` suffix.
@internal
String deriveKeybayAppId(String hostAppId) {
  var hasAlphanumeric = false;
  var validCharacters = true;
  for (final codeUnit in hostAppId.codeUnits) {
    final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
    final isUpper = codeUnit >= 0x41 && codeUnit <= 0x5a;
    final isLower = codeUnit >= 0x61 && codeUnit <= 0x7a;
    final isPunctuation =
        codeUnit == 0x2e || codeUnit == 0x5f || codeUnit == 0x2d;
    hasAlphanumeric |= isDigit || isUpper || isLower;
    validCharacters &= isDigit || isUpper || isLower || isPunctuation;
  }
  if (hostAppId.isEmpty ||
      hostAppId.length > _hostAppIdLimit ||
      !validCharacters ||
      !hasAlphanumeric) {
    throw TailscaleUsageException(
      'appId must be 1..$_hostAppIdLimit characters from '
      '[A-Za-z0-9._-] and contain at least one letter or digit '
      '(got ${hostAppId.length} characters).',
    );
  }
  return '$hostAppId$_keybayNamespaceSuffix';
}

/// Generates one installation-level DEK without any text encoding.
@internal
Uint8List generateStateStoreDek() {
  final random = Random.secure();
  final key = Uint8List(stateStoreDekLength);
  for (var index = 0; index < key.length; index++) {
    key[index] = random.nextInt(256);
  }
  return key;
}
