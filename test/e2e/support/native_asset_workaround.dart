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
/// Call this after `Tailscale.init()` has loaded the library via FFI. The Dart
/// hooks framework re-copies `.dart_tool/lib/libtailscale.so` on every
/// `dart run`, truncating and rewriting the existing inode in place. On Linux,
/// overwriting an mmap'd file kills mappers with SIGBUS. Renaming a freshly
/// copied sibling over the original gives future subprocess hook runs a new
/// inode while the current process keeps its already-mmap'd inode alive.
///
/// TODO: remove this once the project is on a Dart stable that includes
/// dart-lang/sdk@3e020921 ("[dartdev] Delete and create dylibs instead of
/// truncate"), expected in Dart 3.12+.
Future<void> detachLoadedNativeAssetForPeerSubprocesses() async {
  if (!Platform.isLinux) return;

  const libPath = '.dart_tool/lib/libtailscale.so';
  final detachedPath = '$libPath.detached';
  final cp = await Process.run('cp', ['-f', libPath, detachedPath]);
  if (cp.exitCode != 0) {
    throw StateError('cp failed: ${cp.stderr}');
  }
  final mv = await Process.run('mv', [detachedPath, libPath]);
  if (mv.exitCode != 0) {
    throw StateError('mv failed: ${mv.stderr}');
  }
}
