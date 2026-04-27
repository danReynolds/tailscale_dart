import 'dart:io';

/// Prepares the native asset before the E2E test starts peer subprocesses.
///
/// The warmup call forces Dart's native-assets hook to build and cache the
/// shared library once. On Linux, the detach step avoids SIGBUS when later
/// `dart run` subprocesses cause the hook framework to rewrite the same dylib
/// path while the parent process has it mmap'd.
Future<void> prepareNativeAssetForPeerSubprocesses() async {
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
