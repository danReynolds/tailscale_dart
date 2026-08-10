import 'dart:io';

import 'package:path/path.dart' as p;

/// Stable host identity shared by integration-test isolates in one process.
const String processIntegrationAppId = 'dev.tailscale.dart.test.integration';

/// One native configuration identity for every test isolate in this process.
///
/// `package:test` isolates share the loaded Go library, so independently
/// generated roots would violate the same one-owner rule production enforces.
Directory processIntegrationStateRoot() {
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
