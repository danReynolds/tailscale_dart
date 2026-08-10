import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
import 'package:path/path.dart' as p;
import 'package:tailscale/src/keybay_state_custody.dart';

const String _testContainerName = '.tailscale-test-keybay.json';

/// Installs a deliberately test-only persistent Keybay backend.
///
/// Headscale CI runs in a headless Linux session where production Keybay must
/// fail closed. This backend lets the E2E suite prove encrypted-StateStore
/// enrollment and cross-process reconnect without weakening that production
/// policy or claiming a real Secret Service receipt.
void installE2ETestKeybay(String stateRoot) {
  final container = File(p.join(stateRoot, _testContainerName));
  debugOverrideKeybayStorageFactory(
    ({required appId}) =>
        SecretStorage.withBackend(_E2ETestFileBackend(container)),
  );
}

final class _E2ETestFileBackend implements SecretBackend {
  _E2ETestFileBackend(this.container);

  final File container;

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: true);

  Future<Map<String, Uint8List>> _load() async {
    if (!container.existsSync()) return <String, Uint8List>{};
    final decoded = jsonDecode(container.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('invalid E2E Keybay test container');
    }
    return <String, Uint8List>{
      for (final entry in decoded.entries)
        entry.key: Uint8List.fromList(base64Decode(entry.value as String)),
    };
  }

  Future<void> _store(Map<String, Uint8List> values) async {
    if (values.isEmpty) {
      if (container.existsSync()) container.deleteSync();
      return;
    }
    container.parent.createSync(recursive: true);
    final temporary = File(
      '${container.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(
        jsonEncode(<String, String>{
          for (final entry in values.entries)
            entry.key: base64Encode(entry.value),
        }),
        flush: true,
      );
      temporary.renameSync(container.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  @override
  Future<bool> contains(String key) async => (await _load()).containsKey(key);

  @override
  Future<void> delete(String key) async {
    final values = await _load();
    values.remove(key);
    await _store(values);
  }

  @override
  Future<BackendInfo> describe() async => BackendInfo(
    scheme: StorageScheme.encryptedFile,
    available: true,
    locked: false,
    capabilities: capabilities,
    detail: 'test-only file custodian for Headscale E2E',
  );

  @override
  Future<Uint8List?> read(String key) async {
    final value = (await _load())[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<Map<String, Uint8List>> readAll() async => <String, Uint8List>{
    for (final entry in (await _load()).entries)
      entry.key: Uint8List.fromList(entry.value),
  };

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async {
    final values = await _load();
    values[key] = Uint8List.fromList(value);
    await _store(values);
  }
}
