@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/persistent_state_inventory.dart';

void main() {
  late Directory root;
  late String runtimeRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tailscale_inventory_');
    final packageRoot = p.join(root.path, 'tailscale');
    runtimeRoot = p.join(packageRoot, 'tsnet');
    Directory(runtimeRoot).createSync(recursive: true);
    Directory(packageRoot).setPermissionsSync(0x1c0);
    Directory(runtimeRoot).setPermissionsSync(0x1c0);
    File(p.join(packageRoot, 'tailscaled.state.enc'))
      ..writeAsStringSync('ciphertext')
      ..setPermissionsSync(0x180);
    File(p.join(runtimeRoot, 'tailscaled.log.conf'))
      ..writeAsStringSync('credential')
      ..setPermissionsSync(0x180);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('classifies the explicit persistent inventory', () {
    File(p.join(runtimeRoot, 'tailscaled.log1.txt'))
      ..writeAsStringSync('log')
      ..setPermissionsSync(0x180);

    final receipt = auditPersistentRuntimeInventory(root.path);

    expect(receipt, contains(containsPair('category', 'encrypted-state')));
    expect(receipt, contains(containsPair('category', 'log-credential')));
    expect(receipt, contains(containsPair('category', 'sensitive-log')));
  });

  test('rejects an unclassified sidecar', () {
    File(p.join(runtimeRoot, 'surprise.secret'))
      ..writeAsStringSync('unknown')
      ..setPermissionsSync(0x180);

    expect(() => auditPersistentRuntimeInventory(root.path), throwsStateError);
  });

  test('classifies upstream profile netmap cache as sensitive metadata', () {
    final cache = Directory(
      p.join(runtimeRoot, 'profile-data', 'abcd', 'netmap-cache'),
    )..createSync(recursive: true);
    for (final parent in [cache, cache.parent, cache.parent.parent]) {
      parent.setPermissionsSync(0x1c0);
    }
    File(p.join(cache.path, '0123abcdef'))
      ..writeAsStringSync('netmap')
      ..setPermissionsSync(0x180);

    final receipt = auditPersistentRuntimeInventory(root.path);

    expect(
      receipt,
      contains(containsPair('category', 'sensitive-netmap-cache')),
    );
  });

  test('rejects broad permissions on sensitive files', () {
    File(p.join(runtimeRoot, 'tailscaled.log.conf')).setPermissionsSync(0x1a4);

    expect(() => auditPersistentRuntimeInventory(root.path), throwsStateError);
  });

  test('rejects a broad package-root mode', () {
    Directory(p.join(root.path, 'tailscale')).setPermissionsSync(0x1ed);

    expect(() => auditPersistentRuntimeInventory(root.path), throwsStateError);
  });
}

extension on FileSystemEntity {
  void setPermissionsSync(int mode) {
    final result = Process.runSync('chmod', [mode.toRadixString(8), path]);
    if (result.exitCode != 0) {
      throw StateError('chmod failed for $path: ${result.stderr}');
    }
  }
}
