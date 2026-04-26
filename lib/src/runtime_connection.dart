import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'fd_transport.dart';

/// Internal package-native byte-stream connection.
///
/// This is the stable semantic layer above backend-specific data-plane
/// capabilities. POSIX currently backs it with [PosixFdTransport]; other
/// backends can implement the same contract without exposing their carrier.
@internal
final class RuntimeConnection {
  RuntimeConnection._(this._transport);

  /// Adopts a POSIX fd as a runtime connection.
  static Future<RuntimeConnection> adoptPosixFd(
    int fd, {
    int maxReadChunkSize = 64 * 1024,
    int maxPendingWriteBytes = 1024 * 1024,
  }) async {
    final transport = await PosixFdTransport.adopt(
      fd,
      maxReadChunkSize: maxReadChunkSize,
      maxPendingWriteBytes: maxPendingWriteBytes,
    );
    return RuntimeConnection._(transport);
  }

  final PosixFdTransport _transport;
  final _outputDone = Completer<void>();

  /// Single-subscription stream of bytes received from the remote node.
  Stream<Uint8List> get input => _transport.input;

  /// Completes when both halves of the connection are terminal.
  Future<void> get done => _transport.done;

  /// Completes when the output half is terminal.
  Future<void> get outputDone => _outputDone.future;

  /// Writes one byte chunk.
  ///
  /// The bytes are copied before asynchronous delivery, so the caller may reuse
  /// or mutate [bytes] after this method returns.
  Future<void> write(List<int> bytes) {
    if (bytes.isEmpty) return Future.value();
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _transport.write(chunk);
  }

  /// Writes every chunk from [chunks] in order.
  ///
  /// If [chunks] emits an error, that error is propagated and the write side is
  /// left open. This lets callers decide whether to retry, close gracefully, or
  /// abort the whole connection.
  Future<void> writeAll(
    Stream<List<int>> chunks, {
    bool closeOutput = false,
  }) async {
    await for (final chunk in chunks) {
      await write(chunk);
    }
    if (closeOutput) await closeOutputGracefully();
  }

  /// Gracefully closes this side's output while continuing to receive input.
  Future<void> closeOutputGracefully() async {
    await _transport.closeWrite();
    _completeOutputDone();
  }

  /// Closes the whole connection because the application is done with it.
  Future<void> close() async {
    _completeOutputDone();
    await _transport.close();
  }

  /// Aborts the connection.
  ///
  /// For the fd backend this is currently equivalent to [close]: the local
  /// descriptor is shut down and closed. Higher layers can map this to a
  /// protocol reset when using a framed backend.
  Future<void> abort() => close();

  void _completeOutputDone() {
    if (!_outputDone.isCompleted) _outputDone.complete();
  }
}
