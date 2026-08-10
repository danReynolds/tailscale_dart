import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
import 'package:path/path.dart' as p;
import 'package:tailscale/src/keybay_state_custody.dart';
import 'package:tailscale/tailscale.dart';

/// Stable host identity shared by integration-test isolates in one process.
const String processIntegrationAppId = 'dev.tailscale.dart.test.integration';

final _integrationCustodyBackend = _IntegrationCustodyBackend();

/// One native configuration identity for every test isolate in this process.
///
/// `package:test` isolates share the loaded Go library, so independently
/// generated roots would violate the same one-owner rule production enforces.
Directory processIntegrationStateRoot() {
  debugOverrideKeybayStorageFactory(
    ({required appId}) => SecretStorage.withBackend(_integrationCustodyBackend),
  );
  final root = Directory(
    p.join(Directory.systemTemp.path, 'tailscale_dart_integration_$pid'),
  );
  root.createSync(recursive: true);
  return root;
}

/// Clears package-owned state while preserving the configured root inode.
void clearProcessIntegrationState(Directory root) {
  final owned = Directory(p.join(root.path, 'tailscale'));
  if (owned.existsSync()) {
    owned.deleteSync(recursive: true);
  }
}

/// Removes the test DEK and package state through the production reset
/// protocol. Tests must not delete ciphertext independently after custody has
/// been provisioned, because doing so intentionally creates an orphaned key.
Future<void> forgetProcessIntegrationState(Directory root) async {
  await Tailscale.instance.forgetLocalIdentity();
  final owned = Directory(p.join(root.path, 'tailscale'));
  if (owned.existsSync()) {
    throw StateError('forgetLocalIdentity left ${owned.path} behind');
  }
  if (_integrationCustodyBackend.values.containsKey(stateStoreDekEntry)) {
    throw StateError('forgetLocalIdentity left the integration-test DEK');
  }
}

/// Makes the next exact-entry DEK deletion fail before mutation.
void failNextProcessIntegrationCustodyDelete() {
  _integrationCustodyBackend.failNextDelete = true;
}

final class _IntegrationCustodyBackend implements SecretBackend {
  final Map<String, Uint8List> values = <String, Uint8List>{};
  bool failNextDelete = false;

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: false);

  @override
  Future<bool> contains(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw StateError('injected integration-test custody deletion failure');
    }
    values.remove(key);
  }

  @override
  Future<BackendInfo> describe() async => BackendInfo(
    scheme: StorageScheme.nativeItems,
    available: true,
    locked: false,
    capabilities: capabilities,
    detail: 'tailscale_dart integration-test memory backend',
  );

  @override
  Future<Uint8List?> read(String key) async {
    final value = values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<Map<String, Uint8List>> readAll() async => <String, Uint8List>{
    for (final entry in values.entries)
      entry.key: Uint8List.fromList(entry.value),
  };

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async {
    values[key] = Uint8List.fromList(value);
  }
}
