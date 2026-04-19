/// A peer eligible to receive files via Taildrop.
class FileTarget {
  const FileTarget({
    required this.nodeId,
    required this.hostname,
    required this.userLoginName,
  });

  final String nodeId;
  final String hostname;
  final String userLoginName;
}

/// A file that arrived via Taildrop and is waiting to be read or deleted.
class WaitingFile {
  const WaitingFile({required this.name, required this.size});

  /// File name as chosen by the sender.
  final String name;

  /// Total size in bytes.
  final int size;
}

/// Peer-to-peer file transfer ("Taildrop") over the tailnet.
///
/// Reached via [Tailscale.taildrop]. Sends arrive directly between nodes
/// with no intermediary — good fit for mobile-to-desktop sync, collab
/// tools, and anywhere you'd otherwise set up a file server.
class Taildrop {
  const Taildrop();

  /// Peers you can send files to right now (owned-by-you + online +
  /// allowed by ACLs).
  Future<List<FileTarget>> targets() =>
      throw UnimplementedError('taildrop.targets not yet implemented');

  /// Streams [data] to [target] under [name]. [size] is optional but
  /// enables progress reporting on the receiver.
  Future<void> push({
    required FileTarget target,
    required String name,
    required Stream<List<int>> data,
    int? size,
  }) =>
      throw UnimplementedError('taildrop.push not yet implemented');

  /// Files received on this node and not yet picked up.
  Future<List<WaitingFile>> waitingFiles() =>
      throw UnimplementedError('taildrop.waitingFiles not yet implemented');

  /// Blocks until at least one received file is available, or [timeout]
  /// expires. Returns the same shape as [waitingFiles].
  Future<List<WaitingFile>> awaitWaitingFiles({Duration? timeout}) =>
      throw UnimplementedError('taildrop.awaitWaitingFiles not yet implemented');

  /// Streams the contents of a received file. Caller decides where to
  /// persist. Does not delete — call [delete] (or use [deleteOnRead] in
  /// a future revision) once the bytes are durable.
  Future<Stream<List<int>>> get(String name) =>
      throw UnimplementedError('taildrop.get not yet implemented');

  /// Discards a received file without reading it.
  Future<void> delete(String name) =>
      throw UnimplementedError('taildrop.delete not yet implemented');

  /// Reactive stream — emits each newly received file as it arrives.
  Stream<WaitingFile> get onWaitingFile =>
      throw UnimplementedError('taildrop.onWaitingFile not yet implemented');
}
