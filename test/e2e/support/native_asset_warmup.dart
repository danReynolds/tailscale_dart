import 'dart:io';

/// Forces the native-assets hook to build and cache the shared library once.
Future<void> warmUpNativeAssetForPeerSubprocesses() async {
  final warmup = await Process.run(
    Platform.resolvedExecutable,
    ['run', '--enable-experiment=native-assets', 'test/e2e/peer_main.dart'],
    environment: {...Platform.environment, 'PEER_WARMUP': '1'},
  );
  if (warmup.exitCode != 0) {
    throw StateError(
      'Peer warmup failed (exit ${warmup.exitCode})\n'
      'stdout: ${warmup.stdout}\nstderr: ${warmup.stderr}',
    );
  }
}

/// Detaches the loaded Linux `.so` from its directory entry.
///
/// Dart 3.10 and 3.11 can truncate the loaded native asset when a later
/// `dart run` rebuilds it. Replacing the directory entry keeps the current
/// process on its existing inode and prevents SIGBUS while those SDKs remain
/// supported by this package.
///
/// TODO: remove this when the minimum SDK includes dart-lang/sdk@3e020921
/// (delete and recreate dylibs instead of truncating them).
Future<void> detachLoadedNativeAssetForPeerSubprocesses() async {
  if (!Platform.isLinux) return;

  const libPath = '.dart_tool/lib/libtailscale.so';
  final detachedPath = '$libPath.detached';
  final copy = await Process.run('cp', ['-f', libPath, detachedPath]);
  if (copy.exitCode != 0) {
    throw StateError('cp failed: ${copy.stderr}');
  }
  final replace = await Process.run('mv', [detachedPath, libPath]);
  if (replace.exitCode != 0) {
    throw StateError('mv failed: ${replace.stderr}');
  }
}
