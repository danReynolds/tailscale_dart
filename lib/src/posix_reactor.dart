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

/// The native operations the reactor loop performs on its poller and fds.
///
/// Pulling these behind an interface lets the reactor's command processing and
/// main loop be driven deterministically by a fake in tests (see
/// `ReactorTestHarness`), which is the only way to reach the lifecycle race
/// windows — registration failure, idle exit, close ordering — that real-fd
/// integration tests cannot trigger on demand. Production uses
/// [_NativeReactorBackend], a thin forwarder to the cgo `duneReactor*` exports
/// and libc syscall bindings.
abstract interface class _ReactorBackend {
  /// Registers [fd] (transport [id]) with the poller for [events]. Returns 0 on
  /// success, non-zero on failure (the caller must NOT close [fd] on failure —
  /// ownership stays with the main isolate until registration succeeds).
  int register(int fd, int id, int events);

  /// Updates the interest [events] for the registered [fd]. 0 on success.
  int update(int fd, int id, int events);

  /// Removes [fd] from the poller.
  void unregister(int fd);

  /// Blocks until readiness or [timeoutMillis] elapses, filling [events] with up
  /// to [maxEvents] records. Returns the count, or negative on error.
  int wait(
    Pointer<_NativeReactorEvent> events,
    int maxEvents,
    int timeoutMillis,
  );

  /// Tears down the poller; called once on shard exit.
  void closePoller();

  int read(int fd, Pointer<Uint8> buffer, int count);
  int write(int fd, Pointer<Uint8> buffer, int count);
  int shutdown(int fd, int how);

  /// Closes the descriptor (the reactor calls [shutdown] first).
  int closeFd(int fd);

  int get errno;
}

/// Production backend: forwards to the cgo reactor exports (keyed by the shard's
/// native [_handle]) and the libc syscall bindings.
final class _NativeReactorBackend implements _ReactorBackend {
  _NativeReactorBackend(this._handle);

  final int _handle;

  @override
  int register(int fd, int id, int events) =>
      duneReactorRegister(_handle, fd, id, events);

  @override
  int update(int fd, int id, int events) =>
      duneReactorUpdate(_handle, fd, id, events);

  @override
  void unregister(int fd) => duneReactorUnregister(_handle, fd);

  @override
  int wait(
    Pointer<_NativeReactorEvent> events,
    int maxEvents,
    int timeoutMillis,
  ) => duneReactorWait(_handle, events.cast<Void>(), maxEvents, timeoutMillis);

  @override
  void closePoller() => duneReactorClose(_handle);

  @override
  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _PosixBindings.instance.read(fd, buffer, count);

  @override
  int write(int fd, Pointer<Uint8> buffer, int count) =>
      _PosixBindings.instance.write(fd, buffer, count);

  @override
  int shutdown(int fd, int how) => _PosixBindings.instance.shutdown(fd, how);

  @override
  int closeFd(int fd) => _PosixBindings.instance.close(fd);

  @override
  int get errno => _PosixBindings.instance.errno;
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

  unawaited(
    _runFdReactor(_NativeReactorBackend(handle), commands, pendingCommands),
  );
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
  _ReactorBackend backend,
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
          _processReactorCommands(backend, states, metrics, pendingCommands) ||
          sawTransport;
      final idleBeforeWait =
          sawTransport && states.isEmpty && pendingCommands.isEmpty;
      if (tickIdle(isIdle: idleBeforeWait)) return;

      final n = backend.wait(
        events,
        _reactorMaxEvents,
        idleBeforeWait ? _remainingIdleMillis(idle.elapsed) : -1,
      );
      await Future<void>.delayed(Duration.zero);
      sawTransport =
          _processReactorCommands(backend, states, metrics, pendingCommands) ||
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
          _closeReactorState(backend, states, metrics, state, error: error);
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
          _readReactorState(backend, states, metrics, state);
        }
        if (state.closed) continue;
        if (event.events & _reactorEventWrite != 0) {
          _flushReactorWrites(backend, states, metrics, state);
        }
        if (state.closed) continue;
        if (event.events & (_reactorEventHup | _reactorEventError) != 0) {
          _readReactorState(backend, states, metrics, state, eofOnAgain: true);
        }
      }
    }
  } finally {
    for (final state in List<_ReactorTransportState>.of(states.values)) {
      _closeReactorState(backend, states, metrics, state);
    }
    calloc.free(events);
    commands.close();
    backend.closePoller();
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
  _ReactorBackend backend,
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
        // Ownership rule: the reactor owns an fd if and only if it is in
        // `states` (registration succeeded). On a registration failure the fd
        // is NOT ours to close — the main isolate (`_registerWithReactor`'s
        // catch) is still the sole owner and closes it exactly once. Closing
        // here as well would double-close the same fd across two isolates,
        // which under fd-number reuse can tear down an unrelated live
        // descriptor.
        if (states.length >= _reactorMaxRegisteredTransports) {
          replyPort.send('fd reactor transport limit exceeded');
          continue;
        }
        final result = backend.register(fd, id, 0);
        if (result != 0) {
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
        _updateReactorInterest(backend, states, metrics, state);
        continue;
      case _Cmd.disableRead:
        state.readEnabled = false;
        _updateReactorInterest(backend, states, metrics, state);
        continue;
      case _Cmd.inboundConsumed when message.length == 3 && message[2] is int:
        state.pendingInboundBytes -= message[2] as int;
        if (state.pendingInboundBytes < 0) state.pendingInboundBytes = 0;
        _updateReactorInterest(backend, states, metrics, state);
        continue;
      case _Cmd.write
          when message.length == 4 &&
              message[2] is int &&
              message[3] is TransferableTypedData:
        final data = (message[3] as TransferableTypedData)
            .materialize()
            .asUint8List();
        state.writes.add(_ReactorWrite(message[2] as int, data));
        _flushReactorWrites(backend, states, metrics, state);
        continue;
      case _Cmd.shutdownWrite when message.length == 3 && message[2] is int:
        state.closingWrite = true;
        state.shutdownWriteId = message[2] as int;
        _flushReactorWrites(backend, states, metrics, state);
        continue;
      case _Cmd.close:
        _closeReactorState(backend, states, metrics, state);
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
  _ReactorBackend backend,
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
      _updateReactorInterest(backend, states, metrics, state);
      return;
    }
    final readLimit = math.min(
      state.maxReadChunkSize,
      math.min(availableInbound, budget),
    );

    metrics.readSyscalls++;
    final n = backend.read(state.fd, state.scratch.read, readLimit);
    if (n > 0) {
      // `fromList` copies the scratch view synchronously into the transferable,
      // so the buffer can be reused on the next read without an intermediate
      // `Uint8List.fromList` — one fewer full copy of every inbound byte.
      state.pendingInboundBytes += n;
      budget -= n;
      state.eventPort.send(<Object>[
        _Evt.data,
        TransferableTypedData.fromList(<Uint8List>[
          state.scratch.read.asTypedList(n),
        ]),
      ]);
      continue;
    }
    if (n == 0) {
      state.readClosed = true;
      state.readEnabled = false;
      state.eventPort.send(<Object>[_Evt.eof]);
      _updateReactorInterest(backend, states, metrics, state);
      _closeIfFullyDone(backend, states, metrics, state);
      return;
    }
    final errno = backend.errno;
    if (errno == _eintr) continue;
    if (_isAgain(errno)) {
      metrics.againCount++;
      if (eofOnAgain) {
        state.readClosed = true;
        state.readEnabled = false;
        state.eventPort.send(<Object>[_Evt.eof]);
        _updateReactorInterest(backend, states, metrics, state);
        _closeIfFullyDone(backend, states, metrics, state);
      }
      return;
    }
    final error = StateError('read syscall failed errno=$errno');
    metrics.hardErrorCount++;
    state.eventPort.send(<Object>[_Evt.readError, error.toString()]);
    _closeReactorState(backend, states, metrics, state, error: error);
    return;
  }

  _updateReactorInterest(backend, states, metrics, state);
}

/// Drains queued writes for one transport, performing partial-write
/// bookkeeping and `SHUT_WR` once the queue empties under a pending
/// `closeWrite()`. EAGAIN leaves the head write in place with its current
/// offset; the next EPOLLOUT/EVFILT_WRITE wake will resume from there.
void _flushReactorWrites(
  _ReactorBackend backend,
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
      final n = backend.write(state.fd, state.scratch.write, toWrite);
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
        _closeReactorState(backend, states, metrics, state, error: error);
        return;
      }
      final errno = backend.errno;
      if (errno == _eintr) continue;
      if (_isAgain(errno)) {
        metrics.againCount++;
        _updateReactorInterest(backend, states, metrics, state);
        return;
      }
      final error = StateError('write syscall failed errno=$errno');
      metrics.hardErrorCount++;
      state.eventPort.send(<Object>[
        _Evt.writeError,
        write.id,
        error.toString(),
      ]);
      _closeReactorState(backend, states, metrics, state, error: error);
      return;
    }
  }

  if (state.writes.isEmpty && state.closingWrite && !state.writeClosed) {
    final result = backend.shutdown(state.fd, _ShutdownHow.write.value);
    if (result == 0) {
      state.writeClosed = true;
      final id = state.shutdownWriteId;
      if (id != null) state.eventPort.send(<Object>[_Evt.writeOk, id]);
      _closeIfFullyDone(backend, states, metrics, state);
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
      _closeReactorState(backend, states, metrics, state, error: error);
    }
    return;
  }

  _updateReactorInterest(backend, states, metrics, state);
}

/// Promotes a half-closed transport (both read and write halves done) to
/// fully closed. Cheap to call repeatedly — `_closeReactorState` is
/// idempotent on `state.closed`.
void _closeIfFullyDone(
  _ReactorBackend backend,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state,
) {
  if (state.readClosed && state.writeClosed) {
    _closeReactorState(backend, states, metrics, state);
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
  _ReactorBackend backend,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state, {
  Object? error,
}) {
  if (state.closed) return;
  state.closed = true;
  metrics.closeCount++;
  states.remove(state.id);
  backend.unregister(state.fd);
  backend.shutdown(state.fd, _ShutdownHow.readWrite.value);
  backend.closeFd(state.fd);
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
void _updateReactorInterest(
  _ReactorBackend backend,
  Map<int, _ReactorTransportState> states,
  _ReactorMetrics metrics,
  _ReactorTransportState state,
) {
  if (state.closed) return;
  var events = 0;
  if (state.readEnabled &&
      !state.readClosed &&
      state.pendingInboundBytes < state.maxInboundQueuedBytes) {
    events |= _reactorEventRead;
  }
  if (state.writes.isNotEmpty) events |= _reactorEventWrite;
  // Skip the syscall when the kernel already has this exact interest mask. On a
  // steady flow the mask is recomputed after every read drain and every inbound
  // ack but rarely actually changes, so this elides most epoll_ctl/kevent calls
  // (two per kevent update on Darwin).
  if (events == state.lastInterest) return;
  final result = backend.update(state.fd, state.id, events);
  if (result != 0) {
    final error = StateError('native reactor update failed');
    metrics.hardErrorCount++;
    state.eventPort.send(<Object>[_Evt.readError, error.toString()]);
    _closeReactorState(backend, states, metrics, state, error: error);
    return;
  }
  state.lastInterest = events;
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

  /// Last interest mask pushed to the native poller, or -1 if none yet. Lets
  /// [_updateReactorInterest] skip the `epoll_ctl`/`kevent` syscall when the
  /// recomputed mask is unchanged — the common case on a steady read/write flow
  /// where interest is recomputed after every drain and every inbound ack.
  int lastInterest = -1;
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

// ---------------------------------------------------------------------------
// Test support.
//
// These expose the reactor's command processing to deterministic unit tests
// via a fake backend, without spawning a reactor isolate or touching real fds
// or the native poller. They are the seam that makes the lifecycle race
// windows — registration failure, close ordering — testable; real-fd
// integration tests cannot trigger those on demand.
// ---------------------------------------------------------------------------

/// A [_ReactorBackend] that records the native operations the reactor performs
/// instead of executing them, so tests can assert on fd ownership. Test-only.
@visibleForTesting
final class FakeReactorBackend implements _ReactorBackend {
  /// Return value for [register]; set non-zero to simulate a native
  /// registration failure (the reactor must then NOT touch the fd).
  int registerResult = 0;

  /// Return value for [update]; non-zero simulates a poller update failure.
  int updateResult = 0;

  /// fds for which [register] succeeded, in order.
  final List<int> registered = <int>[];

  /// fds passed to [unregister], in order.
  final List<int> unregistered = <int>[];

  /// fds passed to [shutdown], in order.
  final List<int> shutdownFds = <int>[];

  /// fds passed to [closeFd], in order. A double-close shows up as a duplicate.
  final List<int> closedFds = <int>[];

  /// Whether [closePoller] was called.
  bool pollerClosed = false;

  @override
  int register(int fd, int id, int events) {
    if (registerResult == 0) registered.add(fd);
    return registerResult;
  }

  @override
  int update(int fd, int id, int events) => updateResult;

  @override
  void unregister(int fd) => unregistered.add(fd);

  @override
  int wait(
    // ignore: library_private_types_in_public_api
    Pointer<_NativeReactorEvent> events,
    int maxEvents,
    int timeoutMillis,
  ) => 0;

  @override
  void closePoller() => pollerClosed = true;

  @override
  int read(int fd, Pointer<Uint8> buffer, int count) => 0;

  @override
  int write(int fd, Pointer<Uint8> buffer, int count) => count;

  @override
  int shutdown(int fd, int how) {
    shutdownFds.add(fd);
    return 0;
  }

  @override
  int closeFd(int fd) {
    closedFds.add(fd);
    return 0;
  }

  @override
  int get errno => 0;
}

/// Drives the reactor's command processor against a [FakeReactorBackend] in the
/// test isolate, with no spawned isolate, real fds, or native poller. Test-only.
@visibleForTesting
final class ReactorTestHarness {
  ReactorTestHarness(this.backend);

  final FakeReactorBackend backend;
  final Map<int, _ReactorTransportState> _states =
      <int, _ReactorTransportState>{};
  final _ReactorMetrics _metrics = _ReactorMetrics();
  final Queue<Object?> _commands = Queue<Object?>();

  /// Queues a register command. [eventPort]/[replyPort] receive the reactor's
  /// per-transport events and the register reply respectively.
  void enqueueRegister({
    required int id,
    required int fd,
    required SendPort eventPort,
    required SendPort replyPort,
    int maxReadChunkSize = 64 * 1024,
    int maxInboundQueuedBytes = 1024 * 1024,
  }) {
    _commands.add(<Object>[
      _Cmd.register,
      id,
      fd,
      maxReadChunkSize,
      maxInboundQueuedBytes,
      eventPort,
      replyPort,
    ]);
  }

  /// Queues a close command for transport [id].
  void enqueueClose(int id) => _commands.add(<Object>[_Cmd.close, id]);

  /// Drains all queued commands through the reactor's processor.
  void processCommands() =>
      _processReactorCommands(backend, _states, _metrics, _commands);

  /// Transports the reactor currently considers registered.
  int get registeredCount => _states.length;

  /// Whether transport [id] is registered.
  bool isRegistered(int id) => _states.containsKey(id);
}
