import 'dart:io';

import 'package:path/path.dart' as p;

/// Audits the package-owned persistent subtree without reading file contents.
///
/// The returned receipt contains relative paths, classifications, modes, and
/// sizes only, so it can be retained in CI or live-test output without
/// disclosing StateStore ciphertext, log credentials, or operational logs.
List<Map<String, Object>> auditPersistentRuntimeInventory(String stateRoot) {
  final packageRoot = Directory(p.join(stateRoot, 'tailscale'));
  final packageRootType = FileSystemEntity.typeSync(
    packageRoot.path,
    followLinks: false,
  );
  if (packageRootType == FileSystemEntityType.notFound) {
    throw StateError('persistent package root does not exist');
  }
  if (packageRootType != FileSystemEntityType.directory) {
    throw StateError('persistent package root is not a directory');
  }
  final packageRootMode = packageRoot.statSync().mode & 0x1ff;
  if (packageRootMode != 0x1c0) {
    throw StateError('persistent package root mode is not 0700');
  }

  final entities = packageRoot.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  final receipt = <Map<String, Object>>[
    {'path': './', 'category': 'package-root', 'mode': '0700'},
  ];
  for (final entity in entities) {
    final relative = p.relative(entity.path, from: packageRoot.path);
    final stat = entity.statSync();
    final permissions = stat.mode & 0x1ff;
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);

    if (type == FileSystemEntityType.link) {
      throw StateError('$relative is a symbolic link');
    }
    if (type == FileSystemEntityType.directory) {
      if (permissions != 0x1c0) {
        throw StateError('$relative directory mode is not 0700');
      }
      receipt.add({
        'path': '$relative/',
        'category': _persistentDirectoryCategory(relative),
        'mode': '0700',
      });
      continue;
    }
    if (type != FileSystemEntityType.file) {
      throw StateError('$relative is not a regular file');
    }

    final category = _persistentFileCategory(relative);
    if (category == 'public-certificate') {
      if (permissions & 0x12 != 0) {
        throw StateError('$relative is group/other writable');
      }
    } else if (permissions != 0x180) {
      throw StateError('$relative sensitive file mode is not 0600');
    }
    receipt.add({
      'path': relative,
      'category': category,
      'mode': '0${permissions.toRadixString(8).padLeft(3, '0')}',
      'bytes': stat.size,
    });
  }

  if (!receipt.any((entry) => entry['path'] == 'tailscaled.state.enc')) {
    throw StateError('encrypted StateStore envelope is missing');
  }
  if (!receipt.any((entry) => entry['category'] == 'log-credential')) {
    throw StateError('upstream log credential was not inventoried');
  }
  return receipt;
}

String _persistentFileCategory(String relative) {
  if (relative == 'tailscaled.state.enc') return 'encrypted-state';
  if (relative == 'tsnet/tailscaled.log.conf') return 'log-credential';
  if (RegExp(
    r'^tsnet/(tailscaled|sockstats)\.log[12]\.txt$',
  ).hasMatch(relative)) {
    return 'sensitive-log';
  }
  if (relative.startsWith('tsnet/certs/')) {
    if (relative.endsWith('.crt')) return 'public-certificate';
    if (relative.endsWith('.key') || relative.endsWith('.key.pem')) {
      return 'certificate-key';
    }
  }
  if (RegExp(
    r'^tsnet/profile-data/[^/]+/netmap-cache/[0-9a-f]+$',
  ).hasMatch(relative)) {
    return 'sensitive-netmap-cache';
  }
  throw StateError('unclassified persistent runtime artifact: $relative');
}

String _persistentDirectoryCategory(String relative) {
  if (relative == 'tsnet') return 'runtime-directory';
  if (relative == 'tsnet/certs') return 'certificate-directory';
  if (relative == 'tsnet/profile-data' ||
      RegExp(r'^tsnet/profile-data/[^/]+$').hasMatch(relative) ||
      RegExp(r'^tsnet/profile-data/[^/]+/netmap-cache$').hasMatch(relative)) {
    return 'sensitive-metadata-directory';
  }
  throw StateError('unclassified persistent runtime directory: $relative');
}
