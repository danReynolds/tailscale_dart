part of 'fd_transport.dart';

/// Main-isolate handle to one reactor shard.
///
/// Holds the SendPort and native poller handle so callers can post commands
/// without knowing they target an isolate; also owns the shard's lifecycle
/// (lazy spawn, idle exit, retry after a stale-shard race).
final class _SharedFdReactorProxy {
  _SharedFdReactorProxy._({
    required this.shard,
    required SendPort commands,
    required int handle,
  }) : _commands = commands,
       _handle = handle;

  /// Returns the proxy for the shard owning [fd], spawning a new reactor
  /// isolate if none is alive. A second call before the spawn completes
  /// returns the in-flight Future rather than racing two spawns.
  static Future<_SharedFdReactorProxy> forTransport(int fd) {
    final shard = _shardForFd(fd);
    final active = _activeProxies[shard];
    if (active != null && !active._closed) {
      return Future<_SharedFdReactorProxy>.value(active);
    }
    final existing = _instances[shard];
    if (existing != null) return existing;
    final started = _start(shard).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _instances.remove(shard);
      Error.throwWithStackTrace(error, stackTrace);
    });
    _instances[shard] = started;
    return started;
  }

  static final _instances = <int, Future<_SharedFdReactorProxy>>{};
  static final _activeProxies = <int, _SharedFdReactorProxy>{};
  static int _nextTransportId = 0;

  static List<_SharedFdReactorProxy> get activeProxies =>
      <_SharedFdReactorProxy>[
        for (final proxy in _activeProxies.values)
          if (!proxy._closed) proxy,
      ];

  static int _shardForFd(int fd) => fd % _reactorShardCount;

  final int shard;
  final SendPort _commands;
  final int _handle;
  bool _closed = false;

  static Future<_SharedFdReactorProxy> _start(int shard) async {
    final ready = ReceivePort();
    final exit = RawReceivePort();
    final isolate = await Isolate.spawn(
      _fdReactorWorker,
      ready.sendPort,
      debugName: 'tailscale-fd-reactor-$shard',
    );
    isolate.addOnExitListener(exit.sendPort);
    final message = await ready.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('fd reactor worker did not start'),
    );
    ready.close();
    if (message is List &&
        message.length == 3 &&
        message[0] == _Boot.ready &&
        message[1] is SendPort &&
        message[2] is int) {
      final proxy = _SharedFdReactorProxy._(
        shard: shard,
        commands: message[1] as SendPort,
        handle: message[2] as int,
      );
      _activeProxies[shard] = proxy;
      exit.handler = (_) {
        proxy._closed = true;
        if (identical(_activeProxies[shard], proxy)) {
          _activeProxies.remove(shard);
        }
        _instances.remove(shard);
        exit.close();
      };
      return proxy;
    }
    exit.close();
    if (message is List && message.length >= 2 && message[0] == _Boot.error) {
      throw StateError('fd reactor failed to start: ${message[1]}');
    }
    throw StateError('fd reactor returned invalid startup message');
  }

  Future<int> register({
    required int fd,
    required int maxReadChunkSize,
    required int maxInboundQueuedBytes,
    required SendPort eventPort,
  }) async {
    final id = ++_nextTransportId;
    return _request<int>(
      command: (replyPort) => <Object>[
        _Cmd.register,
        id,
        fd,
        maxReadChunkSize,
        maxInboundQueuedBytes,
        eventPort,
        replyPort,
      ],
      timeoutMessage: 'fd reactor register timed out',
      onTimeout: _markClosed,
      parse: (message) {
        if (message == 'ok') return id;
        if (message is String) throw StateError(message);
        throw StateError('fd reactor returned invalid register response');
      },
    );
  }

  Future<PosixFdReactorSnapshot> snapshot() {
    return _request<PosixFdReactorSnapshot>(
      command: (replyPort) => <Object>[_Cmd.snapshot, replyPort],
      timeoutMessage: 'fd reactor snapshot timed out',
      parse: (message) {
        if (message is Map<Object?, Object?>) {
          return PosixFdReactorSnapshot.fromMap(message);
        }
        throw StateError('fd reactor returned invalid snapshot');
      },
    );
  }

  Future<T> _request<T>({
    required List<Object> Function(SendPort replyPort) command,
    required String timeoutMessage,
    required T Function(Object? message) parse,
    void Function()? onTimeout,
  }) async {
    final reply = ReceivePort();
    try {
      send(command(reply.sendPort));
      final message = await reply.first.timeout(
        _reactorRequestTimeout,
        onTimeout: () {
          onTimeout?.call();
          throw StateError(timeoutMessage);
        },
      );
      return parse(message);
    } finally {
      reply.close();
    }
  }

  void send(List<Object> command) {
    if (_closed) {
      _instances.remove(shard);
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
    if (identical(_activeProxies[shard], this)) _activeProxies.remove(shard);
    _instances.remove(shard);
  }

  static bool isRegistrationRetryable(StateError error) =>
      error.message == 'fd reactor wake failed' ||
      error.message == 'fd reactor register timed out';
}

/// Isolate entrypoint for one reactor shard.
///
/// Sets up the command port, creates the native poller, hands the proxy a
/// `ready` handshake (or `error` on failure), then drops into the main loop.
/// Commands arrive asynchronously and are queued in [pendingCommands] for the
/// loop to drain — see `_runFdReactor` for why queuing is necessary.
void _fdReactorWorker(SendPort readyPort) {
  final commands = RawReceivePort();
  final pendingCommands = Queue<Object?>();
  commands.handler = pendingCommands.add;

  final handle = duneReactorCreate();
  if (handle < 0) {
    commands.close();
    readyPort.send(<Object>[_Boot.error, 'native reactor create failed']);
    return;
  }
  readyPort.send(<Object>[_Boot.ready, commands.sendPort, handle]);

  unawaited(_runFdReactor(handle, commands, pendingCommands));
}

/// Reactor main loop.
///
/// Each iteration: drain pending commands, possibly block in the native
/// poller, drain pending commands again, then dispatch ready events. Exits
/// when the shard has been idle past `_reactorIdleGrace` after at least one
/// transport has been seen — the registration retry path on the proxy side
/// will respawn a fresh shard if needed.
///
/// The two `await Future.delayed(Duration.zero)` yields are load-bearing for
/// correctness, not just latency: `RawReceivePort` handlers run on isolate
/// event-queue ticks (not microtasks), so without yielding the loop would
/// never observe a command sent by the main isolate while the reactor is
/// otherwise busy.
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

  // Returns true if the idle grace has elapsed and the loop should exit.
  bool tickIdle({required bool isIdle}) {
    if (!isIdle) {
      idle
        ..stop()
        ..reset();
      return false;
    }
    if (!idle.isRunning) idle.start();
    return idle.elapsed >= _reactorIdleGrace;
  }

  try {
    while (true) {
      await Future<void>.delayed(Duration.zero);
      sawTransport =
          _processReactorCommands(handle, states, metrics, pendingCommands) ||
          sawTransport;
      final idleBeforeWait =
          sawTransport && states.isEmpty && pendingCommands.isEmpty;
      if (tickIdle(isIdle: idleBeforeWait)) return;

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
      if (tickIdle(
        isIdle: sawTransport && states.isEmpty && pendingCommands.isEmpty,
      )) {
        return;
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

/// Time remaining in the idle grace, clamped so the poller wait never
/// returns a 0ms timeout that would spin instead of blocking.
int _remainingIdleMillis(Duration elapsed) {
  final remaining = _reactorIdleGrace - elapsed;
  if (remaining <= Duration.zero) return 0;
  return remaining.inMilliseconds.clamp(1, _reactorIdleGrace.inMilliseconds);
}

/// Drains the queued commands posted by the proxy, mutating `states` and
/// `metrics` in place. Returns true if at least one `register` was processed
/// during this drain — the main loop uses this signal to decide whether the
/// shard has crossed from "bootstrap empty" to "has serviced traffic," which
/// is what arms the idle-exit path.
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

    switch (kind) {
      case _Cmd.snapshot when message.length == 2 && message[1] is SendPort:
        (message[1] as SendPort).send(_reactorSnapshot(states, metrics));
        continue;
      case _Cmd.register when message.length == 7:
        final id = message[1] as int;
        final fd = message[2] as int;
        final maxReadChunkSize = message[3] as int;
        final maxInboundQueuedBytes = message[4] as int;
        final eventPort = message[5] as SendPort;
        final replyPort = message[6] as SendPort;
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
          maxInboundQueuedBytes: maxInboundQueuedBytes,
          eventPort: eventPort,
        );
        registeredTransport = true;
        replyPort.send('ok');
        continue;
    }

    // All remaining commands target a specific transport id at message[1].
    if (message.length < 2 || message[1] is! int) continue;
    final id = message[1] as int;
    final state = states[id];
    if (state == null || state.closed) continue;

    switch (kind) {
      case _Cmd.enableRead:
        state.readEnabled = true;
        _updateReactorInterest(handle, state);
        continue;
      case _Cmd.disableRead:
        state.readEnabled = false;
        _updateReactorInterest(handle, state);
        continue;
      case _Cmd.inboundConsumed when message.length == 3 && message[2] is int:
        state.pendingInboundBytes -= message[2] as int;
        if (state.pendingInboundBytes < 0) state.pendingInboundBytes = 0;
        _updateReactorInterest(handle, state);
        continue;
      case _Cmd.write
          when message.length == 4 &&
              message[2] is int &&
              message[3] is TransferableTypedData:
        final data = (message[3] as TransferableTypedData)
            .materialize()
            .asUint8List();
        state.writes.add(_ReactorWrite(message[2] as int, data));
        _flushReactorWrites(handle, states, metrics, state);
        continue;
      case _Cmd.shutdownWrite when message.length == 3 && message[2] is int:
        state.closingWrite = true;
        state.shutdownWriteId = message[2] as int;
        _flushReactorWrites(handle, states, metrics, state);
        continue;
      case _Cmd.close:
        _closeReactorState(handle, states, metrics, state);
        continue;
    }
  }
  return registeredTransport;
}

/// Drains readable bytes from `state.fd` until the per-iteration byte budget
/// is exhausted, the inbound queue would overfill, the kernel returns EAGAIN,
/// or EOF/error closes the transport.
///
/// `eofOnAgain` is true when the caller already observed HUP/ERR and only
/// needs a final drain attempt; in that mode an EAGAIN is treated as EOF
/// rather than a "come back later" signal.
void _readReactorState(
  int handle,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state, {
  bool eofOnAgain = false,
}) {
  if (!state.readEnabled || state.readClosed || state.closed) return;

  var budget = _reactorReadBudgetBytes;
  while (budget > 0) {
    final availableInbound =
        state.maxInboundQueuedBytes - state.pendingInboundBytes;
    if (availableInbound <= 0) {
      _updateReactorInterest(handle, state);
      return;
    }
    final readLimit = math.min(
      state.maxReadChunkSize,
      math.min(availableInbound, budget),
    );

    metrics.readSyscalls++;
    final n = _PosixBindings.instance.read(
      state.fd,
      state.scratch.read,
      readLimit,
    );
    if (n > 0) {
      final bytes = Uint8List.fromList(state.scratch.read.asTypedList(n));
      state.pendingInboundBytes += n;
      budget -= n;
      state.eventPort.send(<Object>[
        _Evt.data,
        TransferableTypedData.fromList(<Uint8List>[bytes]),
      ]);
      continue;
    }
    if (n == 0) {
      state.readClosed = true;
      state.readEnabled = false;
      state.eventPort.send(<Object>[_Evt.eof]);
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
        state.eventPort.send(<Object>[_Evt.eof]);
        _updateReactorInterest(handle, state);
        _closeIfFullyDone(handle, states, metrics, state);
      }
      return;
    }
    final error = StateError('read syscall failed errno=$errno');
    metrics.hardErrorCount++;
    state.eventPort.send(<Object>[_Evt.readError, error.toString()]);
    _closeReactorState(handle, states, metrics, state, error: error);
    return;
  }

  _updateReactorInterest(handle, state);
}

/// Drains queued writes for one transport, performing partial-write
/// bookkeeping and `SHUT_WR` once the queue empties under a pending
/// `closeWrite()`. EAGAIN leaves the head write in place with its current
/// offset; the next EPOLLOUT/EVFILT_WRITE wake will resume from there.
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
    final toWrite = math.min(
      _reactorWriteChunkBytes,
      math.min(remaining, budget),
    );
    state.scratch.write
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
      final n = _PosixBindings.instance.write(
        state.fd,
        state.scratch.write,
        toWrite,
      );
      if (n > 0) {
        write.offset += n;
        budget -= n;
        if (write.offset == write.data.length) {
          state.writes.removeFirst();
          state.eventPort.send(<Object>[_Evt.writeOk, write.id]);
        }
        break;
      }
      if (n == 0) {
        final error = StateError('write syscall returned 0');
        metrics.hardErrorCount++;
        state.eventPort.send(<Object>[
          _Evt.writeError,
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
        _Evt.writeError,
        write.id,
        error.toString(),
      ]);
      _closeReactorState(handle, states, metrics, state, error: error);
      return;
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
      if (id != null) state.eventPort.send(<Object>[_Evt.writeOk, id]);
      _closeIfFullyDone(handle, states, metrics, state);
    } else {
      final id = state.shutdownWriteId;
      final error = StateError('shutdown(SHUT_WR) failed');
      metrics.hardErrorCount++;
      if (id == null) {
        // Defensive fallback for malformed internal state: no public write
        // completion can be matched, so surface the transport-level failure.
        state.eventPort.send(<Object>[_Evt.readError, error.toString()]);
      } else {
        state.eventPort.send(<Object>[_Evt.writeError, id, error.toString()]);
      }
      _closeReactorState(handle, states, metrics, state, error: error);
    }
    return;
  }

  _updateReactorInterest(handle, state);
}

/// Promotes a half-closed transport (both read and write halves done) to
/// fully closed. Cheap to call repeatedly — `_closeReactorState` is
/// idempotent on `state.closed`.
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

/// Terminal close path for one transport: removes from registry, unregisters
/// from the native poller, shuts down read/write, frees scratch buffers, and
/// notifies the main isolate. Idempotent.
///
/// Pass [error] to fail any still-queued writes; otherwise queued writes are
/// silently discarded (the main isolate has already failed them through its
/// own close path).
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
  state.scratch.dispose();
  if (error != null) {
    for (final write in state.writes) {
      state.eventPort.send(<Object>[
        _Evt.writeError,
        write.id,
        error.toString(),
      ]);
    }
  }
  state.writes.clear();
  state.eventPort.send(<Object>[_Evt.closed]);
}

Map<String, int> _reactorSnapshot(
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
) {
  var queuedInboundBytes = 0;
  var queuedOutboundBytes = 0;
  for (final state in states.values) {
    queuedInboundBytes += state.pendingInboundBytes;
    for (final write in state.writes) {
      queuedOutboundBytes += write.data.length - write.offset;
    }
  }
  return <String, int>{
    'registeredTransports': states.length,
    'queuedInboundBytes': queuedInboundBytes,
    'queuedOutboundBytes': queuedOutboundBytes,
    'wakeEvents': metrics.wakeEvents,
    'readSyscalls': metrics.readSyscalls,
    'writeSyscalls': metrics.writeSyscalls,
    'againCount': metrics.againCount,
    'hardErrorCount': metrics.hardErrorCount,
    'closeCount': metrics.closeCount,
  };
}

/// Recomputes the kernel-side read/write interest mask for one transport from
/// its current state and pushes it to the native poller. Read interest is
/// dropped while paused, half-closed, or back-pressured by a full inbound
/// queue; write interest is asserted only while there is queued data.
void _updateReactorInterest(int handle, _ReactorTransportState state) {
  if (state.closed) return;
  var events = 0;
  if (state.readEnabled &&
      !state.readClosed &&
      state.pendingInboundBytes < state.maxInboundQueuedBytes) {
    events |= _reactorEventRead;
  }
  if (state.writes.isNotEmpty) events |= _reactorEventWrite;
  final result = duneReactorUpdate(handle, state.fd, state.id, events);
  if (result != 0) {
    final error = StateError('native reactor update failed');
    state.eventPort.send(<Object>[_Evt.readError, error.toString()]);
  }
}

/// True if [errno] is the "try again later" signal on either supported
/// platform. EAGAIN and EWOULDBLOCK have the same value on both Linux and
/// Darwin, so a single compare per platform suffices.
bool _isAgain(int errno) => errno == _eagainLinux || errno == _eagainDarwin;

final class _ReactorTransportState {
  _ReactorTransportState({
    required this.id,
    required this.fd,
    required this.maxReadChunkSize,
    required this.maxInboundQueuedBytes,
    required this.eventPort,
  }) : scratch = _ScratchBuffers(
         readBytes: maxReadChunkSize,
         writeBytes: _reactorWriteChunkBytes,
       );

  final int id;
  final int fd;
  final int maxReadChunkSize;
  final int maxInboundQueuedBytes;
  final SendPort eventPort;
  final _ScratchBuffers scratch;
  final writes = Queue<_ReactorWrite>();

  int pendingInboundBytes = 0;
  bool readEnabled = false;
  bool readClosed = false;
  bool closingWrite = false;
  bool writeClosed = false;
  bool closed = false;
  int? shutdownWriteId;
}

final class _ScratchBuffers {
  _ScratchBuffers({required int readBytes, required int writeBytes})
    : read = calloc<Uint8>(readBytes),
      write = calloc<Uint8>(writeBytes);

  final Pointer<Uint8> read;
  final Pointer<Uint8> write;

  void dispose() {
    calloc.free(read);
    calloc.free(write);
  }
}

/// Head-of-queue partial-write bookkeeping.
///
/// [offset] advances as the reactor drains [data] through repeated
/// write(2) calls; EAGAIN leaves the object queued for the next writable event.
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

/// FFI projection of one reactor event.
///
/// The layout must stay byte-identical to:
///   - `tailscale.ReactorEvent` in `go/reactor.go`, and
///   - `DuneReactorEvent` in `go/cmd/dylib/main.go`.
/// All three are { int64 id; int32 events; int32 error/errno; } with natural
/// 8-byte alignment.
final class _NativeReactorEvent extends Struct {
  @Int64()
  external int id;

  @Int32()
  external int events;

  @Int32()
  external int error;
}

/// Direct FFI bindings to the libc syscalls the reactor uses on the hot path.
///
/// We resolve each symbol once at process startup against `DynamicLibrary
/// .process()`; that handle exposes whatever libc the embedding has already
/// loaded, so this works under both standalone Dart and Flutter without
/// shipping a separate native shim.
final class _PosixBindings {
  factory _PosixBindings._() {
    final library = DynamicLibrary.process();
    return _PosixBindings._init(
      library,
      socketpair: library.lookupFunction<_SocketPairNative, _SocketPairDart>(
        'socketpair',
      ),
      read: library.lookupFunction<_ReadNative, _ReadDart>('read'),
      write: library.lookupFunction<_WriteNative, _WriteDart>('write'),
      close: library.lookupFunction<_CloseNative, _CloseDart>('close'),
      shutdown: library.lookupFunction<_ShutdownNative, _ShutdownDart>(
        'shutdown',
      ),
    );
  }

  _PosixBindings._init(
    this._library, {
    required _SocketPairDart socketpair,
    required _ReadDart read,
    required _WriteDart write,
    required _CloseDart close,
    required _ShutdownDart shutdown,
  }) : _socketpair = socketpair,
       _read = read,
       _write = write,
       _close = close,
       _shutdown = shutdown {
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
