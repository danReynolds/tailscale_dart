import 'dart:io';

import 'package:flutter/services.dart';

const _backupPolicy = MethodChannel('dev.tailscale.dart.demo/backup-policy');

/// Creates the demo's durable state root and applies the host-owned backup
/// policy that the package deliberately cannot configure for its embedder.
///
/// Android excludes this exact directory through the app manifest's modern
/// and legacy backup rules. Apple platforms set and read back the filesystem
/// resource value before Tailscale is allowed to use the directory.
Future<void> preparePersistentStateDirectory(
  String path, {
  String? operatingSystem,
}) async {
  await Directory(path).create(recursive: true);
  final platform = operatingSystem ?? Platform.operatingSystem;
  if (platform != 'ios' && platform != 'macos') return;

  final excluded = await _backupPolicy.invokeMethod<bool>(
    'excludeFromBackup',
    path,
  );
  if (excluded != true) {
    throw StateError('backup exclusion was not verified for $path');
  }
}
