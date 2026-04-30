import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'ffi_bindings.dart';

part 'posix_reactor.dart';

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

  /// Reactor-side identifier, assigned by `_SharedFdReactorProxy.register` and
  /// used to address every subsequent command/event for this transport.
  int _transportId = 0;
  int _nextWriteId = 0;
  int _pendingWriteBytes = 0;
  bool _readEnabled = false;

  // -------------------------------------------------------------------------
  // Lifecycle state machine. The transport advances at most once into each
  // terminal flag; the reactor worker mirrors this state per-fd.
  //
  //   open --> readFinished --\
  //                            \--> closed
  //   open --> writeFinished --/
  //   open --> closed (abort/error)
  //
  // `_closed` is the only true terminal state; the read/write half-flags are
  // intermediate so `_maybeCompleteDone` can wait for both halves before
  // completing `done`.
  // -------------------------------------------------------------------------
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
      // Two attempts: the first may race a reactor that is in the process of
      // exiting (idle grace expired between the proxy lookup and the send).
      // `isRegistrationRetryable` distinguishes that race from a real failure;
      // on retry, `forTransport` will spawn a fresh shard.
      for (var attempt = 0; attempt < 2; attempt++) {
        final reactor = await _SharedFdReactorProxy.forTransport(fd);
        try {
          final id = await reactor.register(
            fd: fd,
            maxReadChunkSize: maxReadChunkSize,
            maxInboundQueuedBytes: maxInboundQueuedBytes,
            eventPort: _events.sendPort,
          );
          _reactor = reactor;
          _transportId = id;
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
        _Cmd.write,
        _transportId,
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
      _reactor.send(<Object>[_Cmd.shutdownWrite, _transportId, id]);
    } catch (error) {
      _writeCompletions.remove(id);
      completer.completeError(error);
    }
    return completer.future;
  }

  /// Closes the descriptor and stops delivering input.
  Future<void> close() async {
    if (_closed) return;

    try {
      _reactor.send(<Object>[_Cmd.close, _transportId]);
    } catch (_) {
      closePosixFdForCleanup(fd);
    }
    _teardown(pendingWriteError: StateError('fd transport is closed'));
  }

  void _handleReactorEvent(Object? message) {
    if (_closed) return;
    if (message is! List || message.isEmpty) return;

    switch (message[0]) {
      case _Evt.data when message.length == 2:
        final data = message[1];
        if (data is! TransferableTypedData) return;
        final bytes = data.materialize().asUint8List();
        _input.add(bytes);
        _ackInboundBytes(bytes.length);
        _enableReadIfReady();
        return;
      case _Evt.eof:
        _readFinished = true;
        _closeInput();
        _maybeCompleteDone();
        return;
      case _Evt.readError when message.length >= 2:
        final error = StateError('fd read failed: ${message[1]}');
        _input.addError(error);
        _finishWithError(error);
        return;
      case _Evt.writeOk when message.length >= 2:
        final id = message[1];
        if (id is! int) return;
        final pending = _writeCompletions.remove(id);
        if (pending != null) _pendingWriteBytes -= pending.byteCount;
        pending?.completer.complete();
        if (pending?.byteCount == 0) {
          _writeFinished = true;
          _maybeCompleteDone();
        }
        return;
      case _Evt.writeError when message.length >= 3:
        final id = message[1];
        final pending = id is int ? _writeCompletions.remove(id) : null;
        if (pending != null) _pendingWriteBytes -= pending.byteCount;
        final error = StateError('fd write failed: ${message[2]}');
        pending?.completer.completeError(error);
        _finishWithError(error);
        return;
      case _Evt.closed:
        _teardown(pendingWriteError: StateError('fd transport is closed'));
        return;
    }
  }

  void _enableReadIfReady() {
    if (_closed || _readFinished || _readEnabled) return;
    if (!_input.hasListener || _input.isPaused || _input.isClosed) return;
    _readEnabled = true;
    try {
      _reactor.send(<Object>[_Cmd.enableRead, _transportId]);
    } catch (error) {
      _finishWithError(StateError('fd read enable failed: $error'));
    }
  }

  void _disableRead() {
    if (_closed || !_readEnabled) return;
    _readEnabled = false;
    try {
      _reactor.send(<Object>[_Cmd.disableRead, _transportId]);
    } catch (_) {
      // The close/error path will surface if the reactor is gone.
    }
  }

  void _ackInboundBytes(int bytes) {
    if (_closed || bytes <= 0) return;
    try {
      _reactor.send(<Object>[_Cmd.inboundConsumed, _transportId, bytes]);
    } catch (_) {
      // The close/error path will surface if the reactor is gone.
    }
  }

  void _maybeCompleteDone() {
    if (_closed) return;
    if (!_readFinished || !_writeFinished) return;
    _teardown(closeInput: false);
  }

  void _finishWithError(Object error) {
    _teardown(doneError: error, pendingWriteError: error);
  }

  /// Single terminal path for the main-isolate side of an adopted fd.
  ///
  /// Native ownership is released either because the reactor closed the fd or
  /// because `close()` sent the close command and falls back to direct cleanup
  /// if the reactor is already gone. This method only resolves Dart-facing
  /// resources: finalizer attachment, pending write futures, input stream,
  /// event port, and `done`.
  void _teardown({
    Object? doneError,
    Object? pendingWriteError,
    bool closeInput = true,
  }) {
    if (_closed) return;
    _closed = true;
    _readFinished = true;
    _writeFinished = true;
    _fdFinalizer.detach(this);
    if (pendingWriteError != null) _failPendingWrites(pendingWriteError);
    if (closeInput) _closeInput();
    _stopPorts();
    if (!_done.isCompleted) {
      if (doneError == null) {
        _done.complete();
      } else {
        _done.completeError(doneError);
      }
    }
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
  _PendingWrite(this.byteCount, this.completer);

  final int byteCount;
  final Completer<void> completer;
}

enum _ShutdownHow {
  write(1),
  readWrite(2);

  const _ShutdownHow(this.value);
  final int value;
}

// ---------------------------------------------------------------------------
// POSIX errno + socket constants.
//
// Sourced from <errno.h> / <sys/socket.h>. EAGAIN differs between Linux (11)
// and Darwin (35); the rest are stable across supported POSIX targets.
// ---------------------------------------------------------------------------

const int _eintr = 4;
const int _eagainLinux = 11;
const int _eagainDarwin = 35;
const int _afUnix = 1;
const int _sockStream = 1;

// ---------------------------------------------------------------------------
// Reactor event flag bits. These must match the values exported from the Go
// side in `go/reactor.go` (`ReactorEventRead`, `ReactorEventWrite`, ...) —
// the native poller stamps these into `_NativeReactorEvent.events`.
// ---------------------------------------------------------------------------

const int _reactorEventRead = 1 << 0;
const int _reactorEventWrite = 1 << 1;
const int _reactorEventHup = 1 << 2;
const int _reactorEventError = 1 << 3;
const int _reactorEventWake = 1 << 4;

// ---------------------------------------------------------------------------
// Internal reactor knobs. Per the shared-fd-reactor RFC these are deliberately
// not public API; promote individual values to constructor parameters only
// when a real consumer needs runtime tuning.
// ---------------------------------------------------------------------------

/// Maximum events drained per `epoll_wait` / `kevent` call.
const int _reactorMaxEvents = 128;

/// Hard cap on transports per reactor shard. Adoption past this fails fast
/// with a deterministic error and the caller's fd is closed.
const int _reactorMaxRegisteredTransports = 4096;

/// Number of reactor shards. Sharding is wired through `_shardForFd` but the
/// default workload (private tailnet, dozens of active flows) does not warrant
/// more than one. Bumping this is the single-knob path to scale-out.
const int _reactorShardCount = 1;

/// Per-iteration read drain budget. Caps how many bytes one transport can
/// consume before yielding back to the dispatch loop, so a single hot fd
/// cannot monopolize the reactor.
const int _reactorReadBudgetBytes = 1024 * 1024;

/// Per-write-syscall byte cap. Intentionally decoupled from
/// `maxReadChunkSize`: tuning read chunking should not change write batching.
const int _reactorWriteChunkBytes = 64 * 1024;

/// Per-iteration write drain budget. Same role as the read budget but for
/// outbound flushes.
const int _reactorWriteBudgetBytes = 1024 * 1024;

/// Timeout for synchronous request/reply commands (register, snapshot). Short
/// on purpose: a stuck reactor is a hard failure and the registration retry
/// path will re-spawn the shard cleanly.
const Duration _reactorRequestTimeout = Duration(seconds: 1);

/// How long the reactor stays running with zero registered transports before
/// exiting. Brief enough to release resources on real idleness, long enough to
/// absorb back-to-back adopt/close cycles without an isolate-spawn round-trip.
const Duration _reactorIdleGrace = Duration(milliseconds: 250);

// ---------------------------------------------------------------------------
// Reactor message protocol.
//
// The main isolate and the reactor worker isolate communicate by passing
// `List<Object>` messages over `SendPort`s. The kind tag is the first element.
// These two namespaces document the wire format and prevent typos at call
// sites; runtime values stay strings so messages remain plain Dart objects.
// ---------------------------------------------------------------------------

/// Command kinds: main isolate -> reactor worker.
abstract final class _Cmd {
  static const String register = 'register';
  static const String snapshot = 'snapshot';
  static const String enableRead = 'enableRead';
  static const String disableRead = 'disableRead';
  static const String inboundConsumed = 'inboundConsumed';
  static const String write = 'write';
  static const String shutdownWrite = 'shutdownWrite';
  static const String close = 'close';
}

/// Startup handshake kinds: reactor worker -> proxy start path.
abstract final class _Boot {
  static const String ready = 'ready';
  static const String error = 'error';
}

/// Event kinds: reactor worker -> per-transport event port on the main isolate.
abstract final class _Evt {
  static const String data = 'data';
  static const String eof = 'eof';
  static const String readError = 'readError';
  static const String writeOk = 'writeOk';
  static const String writeError = 'writeError';
  static const String closed = 'closed';
}

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
Future<PosixFdReactorSnapshot?> debugPosixFdReactorSnapshot() async {
  final proxies = _SharedFdReactorProxy.activeProxies;
  if (proxies.isEmpty) return null;
  final snapshots = await Future.wait(proxies.map((proxy) => proxy.snapshot()));
  return PosixFdReactorSnapshot.combine(snapshots);
}

@visibleForTesting
final class PosixFdReactorSnapshot {
  const PosixFdReactorSnapshot({
    required this.registeredTransports,
    required this.queuedInboundBytes,
    required this.queuedOutboundBytes,
    required this.wakeEvents,
    required this.readSyscalls,
    required this.writeSyscalls,
    required this.againCount,
    required this.hardErrorCount,
    required this.closeCount,
  });

  final int registeredTransports;
  final int queuedInboundBytes;
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
      queuedInboundBytes: _readInt(map, 'queuedInboundBytes'),
      queuedOutboundBytes: _readInt(map, 'queuedOutboundBytes'),
      wakeEvents: _readInt(map, 'wakeEvents'),
      readSyscalls: _readInt(map, 'readSyscalls'),
      writeSyscalls: _readInt(map, 'writeSyscalls'),
      againCount: _readInt(map, 'againCount'),
      hardErrorCount: _readInt(map, 'hardErrorCount'),
      closeCount: _readInt(map, 'closeCount'),
    );
  }

  static PosixFdReactorSnapshot combine(
    Iterable<PosixFdReactorSnapshot> snapshots,
  ) {
    var registeredTransports = 0;
    var queuedInboundBytes = 0;
    var queuedOutboundBytes = 0;
    var wakeEvents = 0;
    var readSyscalls = 0;
    var writeSyscalls = 0;
    var againCount = 0;
    var hardErrorCount = 0;
    var closeCount = 0;
    for (final snapshot in snapshots) {
      registeredTransports += snapshot.registeredTransports;
      queuedInboundBytes += snapshot.queuedInboundBytes;
      queuedOutboundBytes += snapshot.queuedOutboundBytes;
      wakeEvents += snapshot.wakeEvents;
      readSyscalls += snapshot.readSyscalls;
      writeSyscalls += snapshot.writeSyscalls;
      againCount += snapshot.againCount;
      hardErrorCount += snapshot.hardErrorCount;
      closeCount += snapshot.closeCount;
    }
    return PosixFdReactorSnapshot(
      registeredTransports: registeredTransports,
      queuedInboundBytes: queuedInboundBytes,
      queuedOutboundBytes: queuedOutboundBytes,
      wakeEvents: wakeEvents,
      readSyscalls: readSyscalls,
      writeSyscalls: writeSyscalls,
      againCount: againCount,
      hardErrorCount: hardErrorCount,
      closeCount: closeCount,
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
