import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A peer eligible to receive files via Taildrop.
@immutable
class FileTarget {
  const FileTarget({
    required this.nodeId,
    required this.hostName,
    required this.userLoginName,
  });

  final String nodeId;
  final String hostName;
  final String userLoginName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileTarget &&
          nodeId == other.nodeId &&
          hostName == other.hostName &&
          userLoginName == other.userLoginName;

  @override
  int get hashCode => Object.hash(nodeId, hostName, userLoginName);

  @override
  String toString() =>
      'FileTarget(nodeId: $nodeId, hostName: $hostName, '
      'userLoginName: $userLoginName)';
}

/// A file that arrived via Taildrop and is waiting to be read or deleted.
@immutable
class WaitingFile {
  const WaitingFile({required this.name, required this.size});

  /// File name as chosen by the sender.
  final String name;

  /// Total size in bytes.
  final int size;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaitingFile && name == other.name && size == other.size;

  @override
  int get hashCode => Object.hash(name, size);

  @override
  String toString() => 'WaitingFile(name: $name, size: $size)';
}

/// Peer-to-peer file transfer ("Taildrop") over the tailnet. Sends
/// travel directly between nodes with no third-party service in the
/// middle — good fit for mobile-to-desktop sync, collab tools, and
/// anywhere you'd otherwise set up a file server.
///
/// See <https://tailscale.com/kb/1106/taildrop> for the full feature
/// (send targets, ACL requirements, receive directory semantics on
/// native Tailscale clients — `package:tailscale` exposes the same
/// LocalAPI surface but leaves file persistence to the caller).
///
/// Reached via [Tailscale.taildrop]. Requires the tailnet operator to
/// have Taildrop enabled in ACLs (on by default); targets are
/// filtered to the set the ACLs allow this node to send to.
class Taildrop {
  /// Library-internal. Reach via `Tailscale.instance.taildrop`.
  @internal
  const Taildrop.internal();

  /// Peers you can send files to right now (owned-by-you + online +
  /// allowed by ACLs).
  Future<List<FileTarget>> targets() =>
      throw UnimplementedError('taildrop.targets not yet implemented');

  /// Streams [data] to [target] under [name]. [size] is optional but
  /// enables progress reporting on the receiver.
  Future<void> push({
    required FileTarget target,
    required String name,
    required Stream<Uint8List> data,
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

  /// Opens a byte stream over a received file. The caller decides where
  /// to persist the contents. Does not delete — call [delete] (or use
  /// [deleteOnRead] in a future revision) once the bytes are durable.
  Stream<Uint8List> openRead(String name) =>
      throw UnimplementedError('taildrop.openRead not yet implemented');

  /// Discards a received file without reading it.
  Future<void> delete(String name) =>
      throw UnimplementedError('taildrop.delete not yet implemented');

  /// Reactive stream — emits each newly received file as it arrives.
  Stream<WaitingFile> get onWaitingFile =>
      throw UnimplementedError('taildrop.onWaitingFile not yet implemented');
}
