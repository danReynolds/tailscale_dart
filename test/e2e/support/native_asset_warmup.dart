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
