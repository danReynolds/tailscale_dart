import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'ffi_bindings.dart';

/// Internal POSIX fd transport primitive.
///
/// The fd is treated as the capability: callers must only pass descriptors
/// returned by the embedded runtime. This layer owns the descriptor after
/// adoption and closes it when the transport is closed.
final class PosixFdTransport {
  PosixFdTransport._(
    this.fd, {
    required this.maxReadChunkSize,
    required this.maxInboundQueuedBytes,
    required this.maxPendingWriteBytes,
  }) {
    _fdFinalizer.attach(this, fd, detach: this);
  }

  /// Adopts [fd] and registers it with the shared POSIX fd reactor.
  static Future<PosixFdTransport> adopt(
    int fd, {
    int maxReadChunkSize = 64 * 1024,
    int maxInboundQueuedBytes = 1024 * 1024,
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
    if (maxInboundQueuedBytes <= 0) {
      throw ArgumentError.value(
        maxInboundQueuedBytes,
        'maxInboundQueuedBytes',
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
      maxInboundQueuedBytes: maxInboundQueuedBytes,
      maxPendingWriteBytes: maxPendingWriteBytes,
    );
    await transport._registerWithReactor();
    return transport;
  }

  /// Adopted OS file descriptor.
  final int fd;

  /// Maximum bytes read from the descriptor per input event.
  final int maxReadChunkSize;

  /// Maximum bytes allowed to be queued for input delivery in Dart.
  final int maxInboundQueuedBytes;

  /// Maximum bytes allowed in the user-space write queue.
  final int maxPendingWriteBytes;

  late final StreamController<Uint8List> _input;
  late final RawReceivePort _events;
  late final _SharedFdReactorProxy _reactor;

  final _done = Completer<void>();
  final _writeCompletions = <int, _PendingWrite>{};

  int _id = 0;
  int _nextWriteId = 0;
  int _pendingWriteBytes = 0;
  int _queuedInboundBytes = 0;
  bool _readEnabled = false;
  bool _closed = false;
  bool _readFinished = false;
  bool _writeFinished = false;
  bool _portsClosed = false;

  /// Single-subscription byte stream read from the fd.
  Stream<Uint8List> get input => _input.stream;

  /// Completes when the transport fully closes.
  Future<void> get done => _done.future;

  Future<void> _registerWithReactor() async {
    _input = StreamController<Uint8List>(
      sync: true,
      onListen: _enableReadIfReady,
      onPause: _disableRead,
      onResume: _enableReadIfReady,
    );
    _events = RawReceivePort(_handleReactorEvent);

    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final reactor = await _SharedFdReactorProxy.instance;
        try {
          final id = await reactor.register(
            fd: fd,
            maxReadChunkSize: maxReadChunkSize,
            eventPort: _events.sendPort,
          );
          _reactor = reactor;
          _id = id;
          return;
        } on StateError catch (error) {
          if (attempt == 0 &&
              _SharedFdReactorProxy.isRegistrationRetryable(error)) {
            continue;
          }
          rethrow;
        }
      }
      throw StateError('fd reactor register retry exhausted');
    } catch (error) {
      _stopPorts();
      _closeInput();
      _fdFinalizer.detach(this);
      closePosixFdForCleanup(fd);
      throw StateError('failed to register fd transport: $error');
    }
  }

  /// Queues [bytes] for ordered delivery to the fd.
  ///
  /// The caller may reuse or mutate [bytes] immediately after this method is
  /// called. The returned future completes when the reactor has written all
  /// bytes to the descriptor.
  Future<void> write(Uint8List bytes) {
    if (bytes.isEmpty) return Future.value();
    if (_closed) return Future.error(StateError('fd transport is closed'));
    if (_writeFinished) {
      return Future.error(StateError('fd transport write side is closed'));
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

    try {
      _reactor.send(<Object>[
        'write',
        _id,
        id,
        TransferableTypedData.fromList(<Uint8List>[copy]),
      ]);
    } catch (error) {
      _writeCompletions.remove(id);
      _pendingWriteBytes -= copy.length;
      completer.completeError(error);
    }
    return completer.future;
  }

  /// Gracefully closes the write half after already queued writes complete.
  Future<void> closeWrite() {
    if (_closed || _writeFinished) return Future.value();

    _writeFinished = true;
    final id = ++_nextWriteId;
    final completer = Completer<void>();
    _writeCompletions[id] = _PendingWrite(0, completer);
    try {
      _reactor.send(<Object>['shutdownWrite', _id, id]);
    } catch (error) {
      _writeCompletions.remove(id);
      completer.completeError(error);
    }
    return completer.future;
  }

  /// Closes the descriptor and stops delivering input.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _readFinished = true;
    _writeFinished = true;

    try {
      _reactor.send(<Object>['close', _id]);
    } catch (_) {
      closePosixFdForCleanup(fd);
    }
    _fdFinalizer.detach(this);
    _failPendingWrites(StateError('fd transport is closed'));
    _closeInput();
    _stopPorts();
    if (!_done.isCompleted) _done.complete();
  }

  void _handleReactorEvent(Object? message) {
    if (_closed) return;
    if (message is! List || message.isEmpty) return;
    final kind = message[0];

    if (kind == 'data' && message.length == 2) {
      final data = message[1];
      if (data is! TransferableTypedData) return;
      final bytes = data.materialize().asUint8List();
      _queuedInboundBytes += bytes.length;
      _input.add(bytes);
      _queuedInboundBytes -= bytes.length;
      _enableReadIfReady();
      return;
    }

    if (kind == 'eof') {
      _readFinished = true;
      _closeInput();
      _maybeCompleteDone();
      return;
    }

    if (kind == 'readError' && message.length >= 2) {
      final error = StateError('fd read failed: ${message[1]}');
      _input.addError(error);
      _closeInput();
      _finishWithError(error);
      return;
    }

    if (kind == 'writeOk' && message.length >= 2) {
      final id = message[1];
      if (id is! int) return;
      final pending = _writeCompletions.remove(id);
      if (pending != null) _pendingWriteBytes -= pending.bytes;
      pending?.completer.complete();
      if (pending?.bytes == 0) {
        _writeFinished = true;
        _maybeCompleteDone();
      }
      return;
    }

    if (kind == 'writeError' && message.length >= 3) {
      final id = message[1];
      final pending = id is int ? _writeCompletions.remove(id) : null;
      if (pending != null) _pendingWriteBytes -= pending.bytes;
      final error = StateError('fd write failed: ${message[2]}');
      pending?.completer.completeError(error);
      _finishWithError(error);
      return;
    }

    if (kind == 'closed') {
      _closed = true;
      _fdFinalizer.detach(this);
      _failPendingWrites(StateError('fd transport is closed'));
      _closeInput();
      _stopPorts();
      if (!_done.isCompleted) _done.complete();
    }
  }

  void _enableReadIfReady() {
    if (_closed || _readFinished || _readEnabled) return;
    if (!_input.hasListener || _input.isPaused || _input.isClosed) return;
    if (_queuedInboundBytes >= maxInboundQueuedBytes) return;
    _readEnabled = true;
    try {
      _reactor.send(<Object>['enableRead', _id]);
    } catch (error) {
      _finishWithError(StateError('fd read enable failed: $error'));
    }
  }

  void _disableRead() {
    if (_closed || !_readEnabled) return;
    _readEnabled = false;
    try {
      _reactor.send(<Object>['disableRead', _id]);
    } catch (_) {
      // The close/error path will surface if the reactor is gone.
    }
  }

  void _maybeCompleteDone() {
    if (_closed) return;
    if (!_readFinished || !_writeFinished) return;
    _closed = true;
    _fdFinalizer.detach(this);
    _stopPorts();
    if (!_done.isCompleted) _done.complete();
  }

  void _finishWithError(Object error) {
    if (_closed) return;
    _closed = true;
    _readFinished = true;
    _writeFinished = true;
    _fdFinalizer.detach(this);
    _failPendingWrites(error);
    _closeInput();
    _stopPorts();
    if (!_done.isCompleted) _done.completeError(error);
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

  void _stopPorts() {
    if (_portsClosed) return;
    _portsClosed = true;
    _events.close();
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
const int _eagainLinux = 11;
const int _eagainDarwin = 35;
const int _afUnix = 1;
const int _sockStream = 1;
const int _reactorEventRead = 1 << 0;
const int _reactorEventWrite = 1 << 1;
const int _reactorEventHup = 1 << 2;
const int _reactorEventError = 1 << 3;
const int _reactorEventWake = 1 << 4;
const int _reactorMaxEvents = 128;
const int _reactorMaxRegisteredTransports = 4096;
const int _reactorWriteBudgetBytes = 1024 * 1024;
const Duration _reactorIdleGrace = Duration(milliseconds: 250);

bool _posixFdTransportProbeComplete = false;

final _fdFinalizer = Finalizer<int>((fd) {
  closePosixFdForCleanup(fd);
});

/// Verifies that the current process exposes the POSIX syscalls needed by the
/// fd transport backend.
///
/// The probe is intentionally small and synchronous. It catches platform or
/// dynamic-linking mismatches at startup instead of surfacing them later from
/// the first TCP/UDP/HTTP transport operation.
void ensurePosixFdTransportAvailable() {
  if (Platform.isWindows || _posixFdTransportProbeComplete) return;

  try {
    final bindings = _PosixBindings.instance;
    if (!bindings.hasErrno) {
      throw StateError('errno symbol could not be resolved');
    }
    _probeSocketPair(bindings);
    _probeReactor();
    _posixFdTransportProbeComplete = true;
  } catch (error) {
    throw StateError('POSIX fd transport probe failed: $error');
  }
}

void closePosixFdForCleanup(int fd) {
  if (fd < 0 || Platform.isWindows) return;
  _PosixBindings.instance.shutdown(fd, _ShutdownHow.readWrite.value);
  _PosixBindings.instance.close(fd);
}

@visibleForTesting
Future<PosixFdReactorSnapshot?> debugPosixFdReactorSnapshot() {
  final proxy = _SharedFdReactorProxy.activeOrNull;
  if (proxy == null) return Future<PosixFdReactorSnapshot?>.value();
  return proxy.snapshot();
}

@visibleForTesting
final class PosixFdReactorSnapshot {
  const PosixFdReactorSnapshot({
    required this.registeredTransports,
    required this.queuedOutboundBytes,
    required this.wakeEvents,
    required this.readSyscalls,
    required this.writeSyscalls,
    required this.againCount,
    required this.hardErrorCount,
    required this.closeCount,
  });

  final int registeredTransports;
  final int queuedOutboundBytes;
  final int wakeEvents;
  final int readSyscalls;
  final int writeSyscalls;
  final int againCount;
  final int hardErrorCount;
  final int closeCount;

  static PosixFdReactorSnapshot fromMap(Map<Object?, Object?> map) {
    return PosixFdReactorSnapshot(
      registeredTransports: _readInt(map, 'registeredTransports'),
      queuedOutboundBytes: _readInt(map, 'queuedOutboundBytes'),
      wakeEvents: _readInt(map, 'wakeEvents'),
      readSyscalls: _readInt(map, 'readSyscalls'),
      writeSyscalls: _readInt(map, 'writeSyscalls'),
      againCount: _readInt(map, 'againCount'),
      hardErrorCount: _readInt(map, 'hardErrorCount'),
      closeCount: _readInt(map, 'closeCount'),
    );
  }

  static int _readInt(Map<Object?, Object?> map, String key) {
    final value = map[key];
    return value is int ? value : 0;
  }
}

void _probeSocketPair(_PosixBindings bindings) {
  final fds = calloc<Int32>(2);
  final writeBuffer = calloc<Uint8>(1);
  final readBuffer = calloc<Uint8>(1);
  var left = -1;
  var right = -1;
  try {
    final result = bindings.socketpair(_afUnix, _sockStream, 0, fds);
    if (result != 0) {
      throw StateError('socketpair failed errno=${bindings.errno}');
    }
    left = fds[0];
    right = fds[1];

    writeBuffer[0] = 0x7a;
    _probeWriteOne(bindings, left, writeBuffer);
    _probeReadOne(bindings, right, readBuffer);
    if (readBuffer[0] != 0x7a) {
      throw StateError('socketpair read/write returned corrupted data');
    }

    final shutdownResult = bindings.shutdown(
      left,
      _ShutdownHow.readWrite.value,
    );
    if (shutdownResult != 0) {
      throw StateError('shutdown failed errno=${bindings.errno}');
    }
  } finally {
    if (left >= 0) {
      bindings.close(left);
    }
    if (right >= 0) {
      bindings.shutdown(right, _ShutdownHow.readWrite.value);
      bindings.close(right);
    }
    calloc.free(fds);
    calloc.free(writeBuffer);
    calloc.free(readBuffer);
  }
}

void _probeReactor() {
  final handle = duneReactorCreate();
  if (handle < 0) {
    throw StateError('reactor create failed');
  }
  final events = calloc<_NativeReactorEvent>(1);
  try {
    final wakeResult = duneReactorWake(handle);
    if (wakeResult != 0) throw StateError('reactor wake failed');
    final n = duneReactorWait(handle, events.cast<Void>(), 1, 1000);
    if (n < 1 || events[0].events & _reactorEventWake == 0) {
      throw StateError('reactor wake wait failed n=$n');
    }
  } finally {
    calloc.free(events);
    duneReactorClose(handle);
  }
}

void _probeWriteOne(_PosixBindings bindings, int fd, Pointer<Uint8> buffer) {
  while (true) {
    final n = bindings.write(fd, buffer, 1);
    if (n == 1) return;
    final errno = bindings.errno;
    if (n < 0 && errno == _eintr) continue;
    throw StateError('write probe failed n=$n errno=$errno');
  }
}

void _probeReadOne(_PosixBindings bindings, int fd, Pointer<Uint8> buffer) {
  while (true) {
    final n = bindings.read(fd, buffer, 1);
    if (n == 1) return;
    final errno = bindings.errno;
    if (n < 0 && errno == _eintr) continue;
    throw StateError('read probe failed n=$n errno=$errno');
  }
}

final class _SharedFdReactorProxy {
  _SharedFdReactorProxy._({required SendPort commands, required int handle})
    : _commands = commands,
      _handle = handle;

  static Future<_SharedFdReactorProxy> get instance {
    final active = _activeProxy;
    if (active != null && !active._closed) {
      return Future<_SharedFdReactorProxy>.value(active);
    }
    return _instance ??= _start();
  }

  static Future<_SharedFdReactorProxy>? _instance;
  static _SharedFdReactorProxy? _activeProxy;
  static int _nextTransportId = 0;

  static _SharedFdReactorProxy? get activeOrNull {
    final active = _activeProxy;
    if (active == null || active._closed) return null;
    return active;
  }

  final SendPort _commands;
  final int _handle;
  bool _closed = false;

  static Future<_SharedFdReactorProxy> _start() async {
    final ready = ReceivePort();
    final exit = RawReceivePort();
    final isolate = await Isolate.spawn(
      _fdReactorWorker,
      ready.sendPort,
      debugName: 'tailscale-fd-reactor',
    );
    isolate.addOnExitListener(exit.sendPort);
    final message = await ready.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('fd reactor worker did not start'),
    );
    ready.close();
    if (message is List &&
        message.length == 3 &&
        message[0] == 'ready' &&
        message[1] is SendPort &&
        message[2] is int) {
      final proxy = _SharedFdReactorProxy._(
        commands: message[1] as SendPort,
        handle: message[2] as int,
      );
      _activeProxy = proxy;
      exit.handler = (_) {
        proxy._closed = true;
        if (identical(_activeProxy, proxy)) _activeProxy = null;
        _instance = null;
        exit.close();
      };
      return proxy;
    }
    exit.close();
    if (message is List && message.length >= 2 && message[0] == 'error') {
      throw StateError('fd reactor failed to start: ${message[1]}');
    }
    throw StateError('fd reactor returned invalid startup message');
  }

  Future<int> register({
    required int fd,
    required int maxReadChunkSize,
    required SendPort eventPort,
  }) async {
    final id = ++_nextTransportId;
    final reply = ReceivePort();
    try {
      send(<Object>[
        'register',
        id,
        fd,
        maxReadChunkSize,
        eventPort,
        reply.sendPort,
      ]);
      final message = await reply.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _markClosed();
          throw StateError('fd reactor register timed out');
        },
      );
      if (message == 'ok') return id;
      throw StateError(message);
    } finally {
      reply.close();
    }
  }

  Future<PosixFdReactorSnapshot> snapshot() async {
    final reply = ReceivePort();
    try {
      send(<Object>['snapshot', reply.sendPort]);
      final message = await reply.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('fd reactor snapshot timed out'),
      );
      if (message is Map<Object?, Object?>) {
        return PosixFdReactorSnapshot.fromMap(message);
      }
      throw StateError('fd reactor returned invalid snapshot');
    } finally {
      reply.close();
    }
  }

  void send(List<Object> command) {
    if (_closed) {
      _instance = null;
      throw StateError('fd reactor is stopped');
    }
    _commands.send(command);
    final result = duneReactorWake(_handle);
    if (result != 0) {
      _markClosed();
      throw StateError('fd reactor wake failed');
    }
  }

  void _markClosed() {
    _closed = true;
    if (identical(_activeProxy, this)) _activeProxy = null;
    _instance = null;
  }

  static bool isRegistrationRetryable(StateError error) =>
      error.message == 'fd reactor wake failed' ||
      error.message == 'fd reactor register timed out';
}

void _fdReactorWorker(SendPort readyPort) {
  final commands = RawReceivePort();
  final pendingCommands = Queue<Object?>();
  commands.handler = pendingCommands.add;

  final handle = duneReactorCreate();
  if (handle < 0) {
    commands.close();
    readyPort.send(<Object>['error', 'native reactor create failed']);
    return;
  }
  readyPort.send(<Object>['ready', commands.sendPort, handle]);

  unawaited(_runFdReactor(handle, commands, pendingCommands));
}

Future<void> _runFdReactor(
  int handle,
  RawReceivePort commands,
  Queue<Object?> pendingCommands,
) async {
  final states = <int, _ReactorTransportState>{};
  final metrics = _ReactorMetrics();
  final events = calloc<_NativeReactorEvent>(_reactorMaxEvents);
  final idle = Stopwatch();
  var sawTransport = false;

  try {
    while (true) {
      await Future<void>.delayed(Duration.zero);
      sawTransport =
          _processReactorCommands(handle, states, metrics, pendingCommands) ||
          sawTransport;
      final idleBeforeWait =
          sawTransport && states.isEmpty && pendingCommands.isEmpty;
      if (idleBeforeWait) {
        if (!idle.isRunning) idle.start();
        if (idle.elapsed >= _reactorIdleGrace) return;
      } else {
        idle
          ..stop()
          ..reset();
      }

      final n = duneReactorWait(
        handle,
        events.cast<Void>(),
        _reactorMaxEvents,
        idleBeforeWait ? _remainingIdleMillis(idle.elapsed) : -1,
      );
      await Future<void>.delayed(Duration.zero);
      sawTransport =
          _processReactorCommands(handle, states, metrics, pendingCommands) ||
          sawTransport;
      final idleAfterWait =
          sawTransport && states.isEmpty && pendingCommands.isEmpty;
      if (idleAfterWait) {
        if (!idle.isRunning) idle.start();
        if (idle.elapsed >= _reactorIdleGrace) return;
      } else {
        idle
          ..stop()
          ..reset();
      }

      if (n < 0) {
        final error = StateError('native reactor wait failed');
        metrics.hardErrorCount++;
        for (final state in List<_ReactorTransportState>.of(states.values)) {
          _closeReactorState(handle, states, metrics, state, error: error);
        }
        return;
      }

      for (var i = 0; i < n; i++) {
        final event = events[i];
        if (event.events & _reactorEventWake != 0) {
          metrics.wakeEvents++;
          continue;
        }
        final state = states[event.id];
        if (state == null || state.closed) continue;
        if (event.events & _reactorEventRead != 0) {
          _readReactorState(handle, states, metrics, state);
        }
        if (state.closed) continue;
        if (event.events & _reactorEventWrite != 0) {
          _flushReactorWrites(handle, states, metrics, state);
        }
        if (state.closed) continue;
        if (event.events & (_reactorEventHup | _reactorEventError) != 0) {
          _readReactorState(handle, states, metrics, state, eofOnAgain: true);
        }
      }
    }
  } finally {
    for (final state in List<_ReactorTransportState>.of(states.values)) {
      _closeReactorState(handle, states, metrics, state);
    }
    calloc.free(events);
    commands.close();
    duneReactorClose(handle);
  }
}

int _remainingIdleMillis(Duration elapsed) {
  final remaining = _reactorIdleGrace - elapsed;
  if (remaining <= Duration.zero) return 0;
  return remaining.inMilliseconds.clamp(1, _reactorIdleGrace.inMilliseconds);
}

bool _processReactorCommands(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  Queue<Object?> pendingCommands,
) {
  var registeredTransport = false;
  while (pendingCommands.isNotEmpty) {
    final message = pendingCommands.removeFirst();
    if (message is! List || message.isEmpty) continue;
    final kind = message[0];

    if (kind == 'snapshot' && message.length == 2 && message[1] is SendPort) {
      (message[1] as SendPort).send(_reactorSnapshot(states, metrics));
      continue;
    }

    if (kind == 'register' && message.length == 6) {
      final id = message[1] as int;
      final fd = message[2] as int;
      final maxReadChunkSize = message[3] as int;
      final eventPort = message[4] as SendPort;
      final replyPort = message[5] as SendPort;
      if (states.length >= _reactorMaxRegisteredTransports) {
        closePosixFdForCleanup(fd);
        replyPort.send('fd reactor transport limit exceeded');
        continue;
      }
      final result = duneReactorRegister(handle, fd, id, 0);
      if (result != 0) {
        closePosixFdForCleanup(fd);
        replyPort.send('native reactor register failed');
        continue;
      }
      states[id] = _ReactorTransportState(
        id: id,
        fd: fd,
        maxReadChunkSize: maxReadChunkSize,
        eventPort: eventPort,
      );
      registeredTransport = true;
      replyPort.send('ok');
      continue;
    }

    if (message.length < 2 || message[1] is! int) continue;
    final id = message[1] as int;
    final state = states[id];
    if (state == null || state.closed) continue;

    if (kind == 'enableRead') {
      state.readEnabled = true;
      _updateReactorInterest(handle, state);
      continue;
    }

    if (kind == 'disableRead') {
      state.readEnabled = false;
      _updateReactorInterest(handle, state);
      continue;
    }

    if (kind == 'write' &&
        message.length == 4 &&
        message[2] is int &&
        message[3] is TransferableTypedData) {
      final data = (message[3] as TransferableTypedData)
          .materialize()
          .asUint8List();
      state.writes.add(_ReactorWrite(message[2] as int, data));
      _flushReactorWrites(handle, states, metrics, state);
      continue;
    }

    if (kind == 'shutdownWrite' && message.length == 3 && message[2] is int) {
      state.closingWrite = true;
      state.shutdownWriteId = message[2] as int;
      _flushReactorWrites(handle, states, metrics, state);
      continue;
    }

    if (kind == 'close') {
      _closeReactorState(handle, states, metrics, state);
      continue;
    }
  }
  return registeredTransport;
}

void _readReactorState(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state, {
  bool eofOnAgain = false,
}) {
  if (!state.readEnabled || state.readClosed || state.closed) return;

  while (true) {
    metrics.readSyscalls++;
    final n = _PosixBindings.instance.read(
      state.fd,
      state.readBuffer,
      state.maxReadChunkSize,
    );
    if (n > 0) {
      final bytes = Uint8List.fromList(state.readBuffer.asTypedList(n));
      state.eventPort.send(<Object>[
        'data',
        TransferableTypedData.fromList(<Uint8List>[bytes]),
      ]);
      return;
    }
    if (n == 0) {
      state.readClosed = true;
      state.readEnabled = false;
      state.eventPort.send(<Object>['eof']);
      _updateReactorInterest(handle, state);
      _closeIfFullyDone(handle, states, metrics, state);
      return;
    }
    final errno = _PosixBindings.instance.errno;
    if (errno == _eintr) continue;
    if (_isAgain(errno)) {
      metrics.againCount++;
      if (eofOnAgain) {
        state.readClosed = true;
        state.readEnabled = false;
        state.eventPort.send(<Object>['eof']);
        _updateReactorInterest(handle, state);
        _closeIfFullyDone(handle, states, metrics, state);
      }
      return;
    }
    final error = StateError('read syscall failed errno=$errno');
    metrics.hardErrorCount++;
    state.eventPort.send(<Object>['readError', error.toString()]);
    _closeReactorState(handle, states, metrics, state, error: error);
    return;
  }
}

void _flushReactorWrites(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state,
) {
  if (state.closed || state.writeClosed) return;

  var budget = _reactorWriteBudgetBytes;
  while (state.writes.isNotEmpty && budget > 0) {
    final write = state.writes.first;
    final remaining = write.data.length - write.offset;
    final toWrite = remaining < budget ? remaining : budget;
    final buffer = calloc<Uint8>(toWrite);
    try {
      buffer
          .asTypedList(toWrite)
          .setAll(
            0,
            Uint8List.sublistView(
              write.data,
              write.offset,
              write.offset + toWrite,
            ),
          );
      while (true) {
        metrics.writeSyscalls++;
        final n = _PosixBindings.instance.write(state.fd, buffer, toWrite);
        if (n > 0) {
          write.offset += n;
          budget -= n;
          if (write.offset == write.data.length) {
            state.writes.removeFirst();
            state.eventPort.send(<Object>['writeOk', write.id]);
          }
          break;
        }
        if (n == 0) {
          final error = StateError('write syscall returned 0');
          metrics.hardErrorCount++;
          state.eventPort.send(<Object>[
            'writeError',
            write.id,
            error.toString(),
          ]);
          _closeReactorState(handle, states, metrics, state, error: error);
          return;
        }
        final errno = _PosixBindings.instance.errno;
        if (errno == _eintr) continue;
        if (_isAgain(errno)) {
          metrics.againCount++;
          _updateReactorInterest(handle, state);
          return;
        }
        final error = StateError('write syscall failed errno=$errno');
        metrics.hardErrorCount++;
        state.eventPort.send(<Object>[
          'writeError',
          write.id,
          error.toString(),
        ]);
        _closeReactorState(handle, states, metrics, state, error: error);
        return;
      }
    } finally {
      calloc.free(buffer);
    }
  }

  if (state.writes.isEmpty && state.closingWrite && !state.writeClosed) {
    final result = _PosixBindings.instance.shutdown(
      state.fd,
      _ShutdownHow.write.value,
    );
    if (result == 0) {
      state.writeClosed = true;
      final id = state.shutdownWriteId;
      if (id != null) state.eventPort.send(<Object>['writeOk', id]);
      _closeIfFullyDone(handle, states, metrics, state);
    } else {
      final id = state.shutdownWriteId ?? 0;
      final error = StateError('shutdown(SHUT_WR) failed');
      metrics.hardErrorCount++;
      state.eventPort.send(<Object>['writeError', id, error.toString()]);
      _closeReactorState(handle, states, metrics, state, error: error);
    }
    return;
  }

  _updateReactorInterest(handle, state);
}

void _closeIfFullyDone(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state,
) {
  if (state.readClosed && state.writeClosed) {
    _closeReactorState(handle, states, metrics, state);
  }
}

void _closeReactorState(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state, {
  Object? error,
}) {
  if (state.closed) return;
  state.closed = true;
  metrics.closeCount++;
  states.remove(state.id);
  duneReactorUnregister(handle, state.fd);
  _PosixBindings.instance.shutdown(state.fd, _ShutdownHow.readWrite.value);
  _PosixBindings.instance.close(state.fd);
  calloc.free(state.readBuffer);
  if (error != null) {
    for (final write in state.writes) {
      state.eventPort.send(<Object>['writeError', write.id, error.toString()]);
    }
  }
  state.writes.clear();
  state.eventPort.send(<Object>['closed']);
}

Map<String, int> _reactorSnapshot(
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
) {
  var queuedOutboundBytes = 0;
  for (final state in states.values) {
    for (final write in state.writes) {
      queuedOutboundBytes += write.data.length - write.offset;
    }
  }
  return <String, int>{
    'registeredTransports': states.length,
    'queuedOutboundBytes': queuedOutboundBytes,
    'wakeEvents': metrics.wakeEvents,
    'readSyscalls': metrics.readSyscalls,
    'writeSyscalls': metrics.writeSyscalls,
    'againCount': metrics.againCount,
    'hardErrorCount': metrics.hardErrorCount,
    'closeCount': metrics.closeCount,
  };
}

void _updateReactorInterest(int handle, _ReactorTransportState state) {
  if (state.closed) return;
  var events = 0;
  if (state.readEnabled && !state.readClosed) events |= _reactorEventRead;
  if (state.writes.isNotEmpty) events |= _reactorEventWrite;
  final result = duneReactorUpdate(handle, state.fd, state.id, events);
  if (result != 0) {
    final error = StateError('native reactor update failed');
    state.eventPort.send(<Object>['readError', error.toString()]);
  }
}

bool _isAgain(int errno) => errno == _eagainLinux || errno == _eagainDarwin;

final class _ReactorTransportState {
  _ReactorTransportState({
    required this.id,
    required this.fd,
    required this.maxReadChunkSize,
    required this.eventPort,
  }) : readBuffer = calloc<Uint8>(maxReadChunkSize);

  final int id;
  final int fd;
  final int maxReadChunkSize;
  final SendPort eventPort;
  final Pointer<Uint8> readBuffer;
  final writes = Queue<_ReactorWrite>();

  bool readEnabled = false;
  bool readClosed = false;
  bool closingWrite = false;
  bool writeClosed = false;
  bool closed = false;
  int? shutdownWriteId;
}

final class _ReactorWrite {
  _ReactorWrite(this.id, this.data);

  final int id;
  final Uint8List data;
  int offset = 0;
}

final class _ReactorMetrics {
  int wakeEvents = 0;
  int readSyscalls = 0;
  int writeSyscalls = 0;
  int againCount = 0;
  int hardErrorCount = 0;
  int closeCount = 0;
}

final class _NativeReactorEvent extends Struct {
  @Int64()
  external int id;

  @Int32()
  external int events;

  @Int32()
  external int error;
}

final class _PosixBindings {
  _PosixBindings._()
    : _library = DynamicLibrary.process(),
      _socketpair = DynamicLibrary.process()
          .lookupFunction<_SocketPairNative, _SocketPairDart>('socketpair'),
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
  final _SocketPairDart _socketpair;
  final _ReadDart _read;
  final _WriteDart _write;
  final _CloseDart _close;
  final _ShutdownDart _shutdown;
  late final _ErrnoLocationDart? _errnoLocation;

  int socketpair(int domain, int type, int protocol, Pointer<Int32> fds) =>
      _socketpair(domain, type, protocol, fds);

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

  bool get hasErrno => _errnoLocation != null;

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

typedef _SocketPairNative = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairDart = int Function(int, int, int, Pointer<Int32>);

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
