import 'package:keybay/keybay.dart';
import 'package:meta/meta.dart';

import 'errors.dart';

/// Keybay entry containing the installation-level StateStore encryption key.
const String stateStoreDekEntry = 'tailscale/state-store/v1/dek';

/// Non-secret label shown for the DEK in platform credential UIs.
const String stateStoreDekLabel = 'Tailscale node-state encryption key';

const String _keybayNamespaceSuffix = '.tailscale';
const int _keybayAppIdLimit = 120;
const int _hostAppIdLimit = _keybayAppIdLimit - 10;

typedef KeybayStorageFactory = SecretStorage Function({required String appId});

SecretStorage _createKeybayStorage({required String appId}) =>
    SecretStorage(appId: appId);

/// The frozen, lazy Keybay binding for Tailscale's encrypted StateStore DEK.
///
/// Constructing this object performs no platform storage work. The Keybay
/// backend is resolved only when [createStorage] is called by a later
/// persistent lifecycle operation. Ephemeral runtimes must never call it.
@internal
final class KeybayStateCustodyBinding {
  KeybayStateCustodyBinding({
    required this.hostAppId,
    KeybayStorageFactory storageFactory = _createKeybayStorage,
  }) : keybayNamespace = deriveKeybayAppId(hostAppId),
       _storageFactory = storageFactory;

  /// Stable identifier supplied by the embedding application.
  final String hostAppId;

  /// Dedicated Keybay namespace; never shared with the host's other secrets.
  final String keybayNamespace;

  final KeybayStorageFactory _storageFactory;

  /// Resolves the production Keybay container on the calling isolate.
  ///
  /// R4a intentionally leaves this unwired. R4c calls it once at the custody
  /// boundary and owns the resulting container for that lifecycle.
  SecretStorage createStorage() => _storageFactory(appId: keybayNamespace);
}

/// Validates [hostAppId] and derives Tailscale's dedicated Keybay namespace.
///
/// Keybay permits at most 120 characters. The reserved `.tailscale` suffix is
/// ten characters, leaving a 110-character host-identifier budget.
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
