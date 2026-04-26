import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Internal POSIX fd transport primitive.
///
/// The fd is treated as the capability: callers must only pass descriptors
/// returned by the embedded runtime. This layer owns the descriptor after
/// adoption and closes it when the transport is closed.
final class PosixFdTransport {
  PosixFdTransport._(
    this.fd, {
    required this.maxReadChunkSize,
    required this.maxPendingWriteBytes,
  }) {
    _fdFinalizer.attach(this, fd, detach: this);
  }

  /// Adopts [fd] and starts asynchronous read/write workers.
  static Future<PosixFdTransport> adopt(
    int fd, {
    int maxReadChunkSize = 64 * 1024,
    int maxPendingWriteBytes = 1024 * 1024,
  }) async {
    if (Platform.isWindows) {
      throw UnsupportedError('POSIX fd transport is not available on Windows.');
    }
    if (fd < 0) throw ArgumentError.value(fd, 'fd', 'must be non-negative');
    if (maxReadChunkSize <= 0) {
      throw ArgumentError.value(
        maxReadChunkSize,
        'maxReadChunkSize',
        'must be positive',
      );
    }
    if (maxPendingWriteBytes <= 0) {
      throw ArgumentError.value(
        maxPendingWriteBytes,
        'maxPendingWriteBytes',
        'must be positive',
      );
    }

    final transport = PosixFdTransport._(
      fd,
      maxReadChunkSize: maxReadChunkSize,
      maxPendingWriteBytes: maxPendingWriteBytes,
    );
    await transport._startWorkers();
    return transport;
  }

  /// Adopted OS file descriptor.
  final int fd;

  /// Maximum bytes read from the descriptor per input event.
  final int maxReadChunkSize;

  /// Maximum bytes allowed in the user-space write queue.
  final int maxPendingWriteBytes;

  late final StreamController<Uint8List> _input;
  final _done = Completer<void>();
  final _writeCompletions = <int, _PendingWrite>{};

  late final RawReceivePort _readerEvents;
  late final RawReceivePort _writerEvents;

  SendPort? _readerCommands;
  SendPort? _writerCommands;

  int _nextWriteId = 0;
  int _pendingWriteBytes = 0;
  bool _readInFlight = false;
  bool _closed = false;
  bool _readFinished = false;
  bool _writeFinished = false;
  bool _fdClosed = false;
  bool _portsClosed = false;

  /// Single-subscription byte stream read from the fd.
  Stream<Uint8List> get input => _input.stream;

  /// Completes when the transport fully closes.
  Future<void> get done => _done.future;

  Future<void> _startWorkers() async {
    _input = StreamController<Uint8List>(
      sync: true,
      onListen: _requestReadIfReady,
      onResume: _requestReadIfReady,
    );
    final readerReady = Completer<SendPort>();
    final writerReady = Completer<SendPort>();

    _readerEvents = RawReceivePort((Object? message) {
      if (message is List && message.length == 2 && message[0] == 'ready') {
        final sendPort = message[1];
        if (sendPort is SendPort && !readerReady.isCompleted) {
          _readerCommands = sendPort;
          readerReady.complete(sendPort);
          _requestReadIfReady();
        }
        return;
      }
      _handleReaderEvent(message);
    });
    _writerEvents = RawReceivePort((Object? message) {
      if (message is List && message.length == 2 && message[0] == 'ready') {
        final sendPort = message[1];
        if (sendPort is SendPort && !writerReady.isCompleted) {
          _writerCommands = sendPort;
          writerReady.complete(sendPort);
        }
        return;
      }
      _handleWriterEvent(message);
    });

    try {
      await Isolate.spawn(_fdReadWorker, <Object>[
        fd,
        maxReadChunkSize,
        _readerEvents.sendPort,
      ], debugName: 'tailscale-fd-read-$fd');
      await Isolate.spawn(_fdWriteWorker, <Object>[
        fd,
        _writerEvents.sendPort,
      ], debugName: 'tailscale-fd-write-$fd');
      await readerReady.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('fd reader worker did not start'),
      );
      await writerReady.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('fd writer worker did not start'),
      );
    } catch (e) {
      await close();
      throw StateError('failed to start fd transport workers: $e');
    }
  }

  /// Queues [bytes] for ordered delivery to the fd.
  ///
  /// The caller may reuse or mutate [bytes] immediately after this method is
  /// called. The returned future completes when the worker has written all
  /// bytes to the descriptor.
  Future<void> write(Uint8List bytes) {
    if (bytes.isEmpty) return Future.value();
    if (_closed) return Future.error(StateError('fd transport is closed'));
    if (_writeFinished) {
      return Future.error(StateError('fd transport write side is closed'));
    }
    if (_writerCommands == null) {
      return Future.error(StateError('fd writer worker is not ready'));
    }

    final copy = Uint8List.fromList(bytes);
    if (_pendingWriteBytes + copy.length > maxPendingWriteBytes) {
      return Future.error(
        StateError(
          'fd transport write queue exceeded $maxPendingWriteBytes bytes',
        ),
      );
    }

    final id = ++_nextWriteId;
    final completer = Completer<void>();
    _pendingWriteBytes += copy.length;
    _writeCompletions[id] = _PendingWrite(copy.length, completer);
    _writerCommands!.send(<Object>[
      'write',
      id,
      TransferableTypedData.fromList(<Uint8List>[copy]),
    ]);
    return completer.future;
  }

  /// Gracefully closes the write half after already queued writes complete.
  Future<void> closeWrite() {
    if (_closed || _writeFinished) return Future.value();
    if (_writerCommands == null) {
      return Future.error(StateError('fd writer worker is not ready'));
    }

    _writeFinished = true;
    final id = ++_nextWriteId;
    final completer = Completer<void>();
    _writeCompletions[id] = _PendingWrite(0, completer);
    _writerCommands!.send(<Object>['shutdownWrite', id]);
    return completer.future;
  }

  /// Closes the descriptor and stops delivering input.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _readFinished = true;
    _writeFinished = true;

    _writerCommands?.send(<Object>['close']);
    _failPendingWrites(StateError('fd transport is closed'));
    _shutdown(_ShutdownHow.readWrite);
    _closeFd();
    _stopWorkersAndPorts();
    _closeInput();
    if (!_done.isCompleted) _done.complete();
  }

  void _handleReaderEvent(Object? message) {
    if (_closed) return;
    _readInFlight = false;
    if (message == null) {
      _readFinished = true;
      _closeInput();
      _maybeCompleteDone();
      return;
    }
    if (message is TransferableTypedData) {
      _input.add(message.materialize().asUint8List());
      _requestReadIfReady();
      return;
    }
    if (message is List && message.length == 2 && message[0] == 'error') {
      final error = StateError('fd read failed: ${message[1]}');
      _input.addError(error);
      _closeInput();
      _closed = true;
      _failPendingWrites(error);
      _closeFd();
      _stopWorkersAndPorts();
      if (!_done.isCompleted) _done.completeError(error);
    }
  }

  void _requestReadIfReady() {
    if (_closed || _readFinished || _readInFlight) return;
    if (_readerCommands == null) return;
    if (!_input.hasListener || _input.isPaused || _input.isClosed) return;
    _readInFlight = true;
    _readerCommands!.send(<Object>['read']);
  }

  void _handleWriterEvent(Object? message) {
    if (_closed) return;
    if (message is! List || message.length < 2) return;
    final kind = message[0];
    final id = message[1];
    if (id is! int) return;

    final pending = _writeCompletions.remove(id);
    if (pending != null) _pendingWriteBytes -= pending.bytes;

    if (kind == 'ok') {
      pending?.completer.complete();
      if (pending?.bytes == 0) {
        _writeFinished = true;
        _maybeCompleteDone();
      }
      return;
    }

    if (kind == 'error') {
      final detail = message.length >= 3 ? message[2] : 'unknown error';
      final error = StateError('fd write failed: $detail');
      pending?.completer.completeError(error);
      _closed = true;
      _failPendingWrites(error);
      _shutdown(_ShutdownHow.readWrite);
      _closeFd();
      _stopWorkersAndPorts();
      _closeInput();
      if (!_done.isCompleted) _done.completeError(error);
    }
  }

  void _maybeCompleteDone() {
    if (_closed) return;
    if (!_readFinished || !_writeFinished) return;

    _closed = true;
    _closeFd();
    _stopWorkersAndPorts();
    if (!_done.isCompleted) _done.complete();
  }

  void _failPendingWrites(Object error) {
    final pending = List<_PendingWrite>.of(_writeCompletions.values);
    _writeCompletions.clear();
    _pendingWriteBytes = 0;
    for (final write in pending) {
      if (!write.completer.isCompleted) {
        write.completer.completeError(error);
      }
    }
  }

  void _closeInput() {
    if (!_input.isClosed) unawaited(_input.close());
  }

  void _shutdown(_ShutdownHow how) {
    if (_fdClosed) return;
    _PosixBindings.instance.shutdown(fd, how.value);
  }

  void _closeFd() {
    if (_fdClosed) return;
    _fdClosed = true;
    _fdFinalizer.detach(this);
    _PosixBindings.instance.close(fd);
  }

  void _stopWorkersAndPorts() {
    _readerCommands?.send(<Object>['close']);
    _writerCommands?.send(<Object>['close']);
    if (_portsClosed) return;
    _portsClosed = true;
    _readerEvents.close();
    _writerEvents.close();
  }
}

final class _PendingWrite {
  _PendingWrite(this.bytes, this.completer);

  final int bytes;
  final Completer<void> completer;
}

enum _ShutdownHow {
  write(1),
  readWrite(2);

  const _ShutdownHow(this.value);
  final int value;
}

const int _eintr = 4;

final _fdFinalizer = Finalizer<int>((fd) {
  closePosixFdForCleanup(fd);
});

void closePosixFdForCleanup(int fd) {
  if (fd < 0 || Platform.isWindows) return;
  _PosixBindings.instance.shutdown(fd, _ShutdownHow.readWrite.value);
  _PosixBindings.instance.close(fd);
}

void _fdReadWorker(List<Object> args) {
  final fd = args[0] as int;
  final maxReadChunkSize = args[1] as int;
  final sendPort = args[2] as SendPort;
  final commands = ReceivePort();
  sendPort.send(<Object>['ready', commands.sendPort]);

  final buffer = calloc<Uint8>(maxReadChunkSize);
  unawaited(() async {
    try {
      await for (final message in commands) {
        if (message is! List || message.isEmpty) continue;
        if (message[0] == 'close') {
          commands.close();
          return;
        }
        if (message[0] != 'read') continue;

        int n;
        while (true) {
          n = _PosixBindings.instance.read(fd, buffer, maxReadChunkSize);
          if (n >= 0) break;
          final errno = _PosixBindings.instance.errno;
          if (errno == _eintr) continue;
          sendPort.send(<Object>['error', 'read syscall failed errno=$errno']);
          commands.close();
          return;
        }

        if (n == 0) {
          sendPort.send(null);
          commands.close();
          return;
        }
        final bytes = Uint8List.fromList(buffer.asTypedList(n));
        sendPort.send(TransferableTypedData.fromList(<Uint8List>[bytes]));
      }
    } finally {
      calloc.free(buffer);
    }
  }());
}

void _fdWriteWorker(List<Object> args) {
  final fd = args[0] as int;
  final sendPort = args[1] as SendPort;
  final commands = ReceivePort();
  sendPort.send(<Object>['ready', commands.sendPort]);

  unawaited(() async {
    await for (final message in commands) {
      if (message is! List || message.isEmpty) continue;
      final kind = message[0];
      if (kind == 'close') {
        commands.close();
        return;
      }
      if (message.length < 2 || message[1] is! int) continue;
      final id = message[1] as int;

      if (kind == 'write') {
        if (message.length < 3 || message[2] is! TransferableTypedData) {
          sendPort.send(<Object>['error', id, 'missing write payload']);
          continue;
        }
        final data = (message[2] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final error = _writeAll(fd, data);
        if (error == null) {
          sendPort.send(<Object>['ok', id]);
        } else {
          sendPort.send(<Object>['error', id, error]);
        }
        continue;
      }

      if (kind == 'shutdownWrite') {
        final result = _PosixBindings.instance.shutdown(
          fd,
          _ShutdownHow.write.value,
        );
        if (result == 0) {
          sendPort.send(<Object>['ok', id]);
        } else {
          sendPort.send(<Object>[
            'error',
            id,
            'shutdown(SHUT_WR) returned $result',
          ]);
        }
      }
    }
  }());
}

String? _writeAll(int fd, Uint8List data) {
  final buffer = calloc<Uint8>(data.length);
  try {
    buffer.asTypedList(data.length).setAll(0, data);
    var offset = 0;
    while (offset < data.length) {
      final pointer = buffer + offset;
      final n = _PosixBindings.instance.write(
        fd,
        pointer,
        data.length - offset,
      );
      if (n < 0) {
        final errno = _PosixBindings.instance.errno;
        if (errno == _eintr) continue;
        return 'write syscall failed errno=$errno';
      }
      if (n == 0) return 'write syscall returned 0';
      offset += n;
    }
    return null;
  } finally {
    calloc.free(buffer);
  }
}

final class _PosixBindings {
  _PosixBindings._()
    : _library = DynamicLibrary.process(),
      _read = DynamicLibrary.process().lookupFunction<_ReadNative, _ReadDart>(
        'read',
      ),
      _write = DynamicLibrary.process()
          .lookupFunction<_WriteNative, _WriteDart>('write'),
      _close = DynamicLibrary.process()
          .lookupFunction<_CloseNative, _CloseDart>('close'),
      _shutdown = DynamicLibrary.process()
          .lookupFunction<_ShutdownNative, _ShutdownDart>('shutdown') {
    _errnoLocation = _lookupErrnoLocation(_library);
  }

  static final instance = _PosixBindings._();

  final DynamicLibrary _library;
  final _ReadDart _read;
  final _WriteDart _write;
  final _CloseDart _close;
  final _ShutdownDart _shutdown;
  late final _ErrnoLocationDart? _errnoLocation;

  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _read(fd, buffer, count);

  int write(int fd, Pointer<Uint8> buffer, int count) =>
      _write(fd, buffer, count);

  int close(int fd) => _close(fd);

  int shutdown(int fd, int how) => _shutdown(fd, how);

  int get errno {
    final location = _errnoLocation;
    if (location == null) return 0;
    final pointer = location();
    if (pointer == nullptr) return 0;
    return pointer.value;
  }

  static _ErrnoLocationDart? _lookupErrnoLocation(DynamicLibrary library) {
    for (final symbol in const ['__errno_location', '__errno', '__error']) {
      try {
        return library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
          symbol,
        );
      } catch (_) {
        // Try the next platform spelling.
      }
    }
    return null;
  }
}

typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);

typedef _WriteNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Uint8>, int);

typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);

typedef _ShutdownNative = Int32 Function(Int32, Int32);
typedef _ShutdownDart = int Function(int, int);

typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();
