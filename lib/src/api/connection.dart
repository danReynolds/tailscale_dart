import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io' show sleep;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../errors.dart';
import '../fd_transport.dart' show closePosixFdForCleanup;
import '../ffi_bindings.dart' as native;
import '../runtime_connection.dart';
import 'identity.dart';

const int _maxPendingAcceptedConnections = 128;
const int _maxConsecutiveAcceptErrors = 20;

/// A tailnet endpoint attached to a transport object.
@immutable
final class TailscaleEndpoint {
  const TailscaleEndpoint({required this.address, required this.port});

  /// Endpoint address.
  ///
  /// Dial/bind APIs may accept IPs, MagicDNS names, or an empty bind address
  /// depending on context. Observed connection endpoints returned by the
  /// runtime are literal tailnet addresses whenever the backend can resolve
  /// them.
  final String address;

  /// TCP or UDP port.
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleEndpoint &&
          address == other.address &&
          port == other.port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => address.isEmpty ? ':$port' : '$address:$port';
}

/// One full-duplex byte stream over the tailnet.
abstract interface class TailscaleConnection {
  /// Local tailnet endpoint for this connection.
  TailscaleEndpoint get local;

  /// Remote tailnet endpoint for this connection.
  TailscaleEndpoint get remote;

  /// Remote node identity, resolved at accept time via a WhoIs lookup.
  ///
  /// Populated for connections accepted by a [TailscaleListener] when the
  /// remote IP maps to a known tailnet node. Null for outbound dials, and
  /// null when the accept-time lookup found nothing or failed — resolution
  /// is best-effort and never blocks an accept. For a hard identity check
  /// you can still call `Tailscale.instance.whois(remote.address)`.
  TailscaleNodeIdentity? get identity;

  /// Single-subscription byte stream received from the remote node.
  ///
  /// Listen once. Pausing the subscription applies local backpressure for
  /// stream transports; canceling it means the application is done reading.
  Stream<Uint8List> get input;

  /// Write half of the connection.
  TailscaleConnectionOutput get output;

  /// Completes when the full connection is terminal.
  Future<void> get done;

  /// Application-level close: the caller is done with the whole connection.
  ///
  /// This closes the local read and write sides. It may discard unread input
  /// and fail pending writes. To only signal EOF to the remote while continuing
  /// to read, call [TailscaleConnectionOutput.close] instead.
  Future<void> close();

  /// Immediate local teardown/reset.
  ///
  /// The fd backend currently maps this to the same local descriptor shutdown
  /// as [close].
  Future<void> abort();
}

/// Write half of a [TailscaleConnection].
abstract interface class TailscaleConnectionOutput {
  /// Writes one chunk.
  ///
  /// Completion means bytes were accepted by the local transport, not that the
  /// remote node received or read them.
  Future<void> write(List<int> bytes);

  /// Writes all chunks in order.
  ///
  /// If [chunks] emits an error, that error is propagated and the output is
  /// left open so the caller can choose recovery behavior.
  Future<void> writeAll(Stream<List<int>> chunks, {bool close = false});

  /// Gracefully closes the write half.
  Future<void> close();

  /// Completes when this write half is terminal.
  Future<void> get done;
}

/// Tailnet TCP listener.
abstract interface class TailscaleListener {
  /// Local tailnet endpoint accepted by this listener.
  TailscaleEndpoint get local;

  /// Single-subscription stream of accepted connections.
  ///
  /// Listening starts a background accept loop. Canceling the subscription
  /// closes the listener. Paused subscriptions use a bounded pending-accept
  /// queue; overflow accepts are closed instead of buffered without limit.
  Stream<TailscaleConnection> get connections;

  /// Stops accepting connections.
  Future<void> close();

  /// Completes when [close] has completed.
  Future<void> get done;
}

@internal
Future<TailscaleConnection> createFdTailscaleConnection({
  required int fd,
  required TailscaleEndpoint local,
  required TailscaleEndpoint remote,
  TailscaleNodeIdentity? identity,
}) async {
  final runtime = await RuntimeConnection.adoptPosixFd(fd);
  return _TailscaleConnection(runtime, local, remote, identity);
}

@internal
TailscaleListener createFdTailscaleListener({
  required int listenerId,
  required TailscaleEndpoint local,
  required Future<void> Function(int listenerId) closeFn,
}) => _FdTailscaleListener(
  listenerId: listenerId,
  local: local,
  closeFn: closeFn,
);

final class _TailscaleConnection implements TailscaleConnection {
  _TailscaleConnection(this._runtime, this.local, this.remote, this.identity)
    : output = _TailscaleConnectionOutput(_runtime);

  final RuntimeConnection _runtime;

  @override
  final TailscaleEndpoint local;

  @override
  final TailscaleEndpoint remote;

  @override
  final TailscaleNodeIdentity? identity;

  @override
  Stream<Uint8List> get input => _runtime.input;

  @override
  final TailscaleConnectionOutput output;

  @override
  Future<void> get done => _runtime.done;

  @override
  Future<void> close() => _runtime.close();

  @override
  Future<void> abort() => _runtime.abort();
}

final class _TailscaleConnectionOutput implements TailscaleConnectionOutput {
  _TailscaleConnectionOutput(this._runtime);

  final RuntimeConnection _runtime;

  @override
  Future<void> get done => _runtime.outputDone;

  @override
  Future<void> write(List<int> bytes) => _runtime.write(bytes);

  @override
  Future<void> writeAll(Stream<List<int>> chunks, {bool close = false}) =>
      _runtime.writeAll(chunks, closeOutput: close);

  @override
  Future<void> close() => _runtime.closeOutputGracefully();
}

final class _FdTailscaleListener implements TailscaleListener {
  _FdTailscaleListener({
    required this.listenerId,
    required this.local,
    required Future<void> Function(int listenerId) closeFn,
  }) : _closeFn = closeFn {
    _connections = StreamController<TailscaleConnection>(
      onListen: _startAcceptLoop,
      onResume: _drainPendingAccepts,
      onCancel: close,
    );
    // `close()` can complete `done` with an error (e.g. worker death) and also
    // rethrow it; callers that catch the throw but never await `done` would
    // otherwise leak an unhandled async error. `ignore()` absorbs the orphaned
    // completion while awaiters still observe it.
    _done.future.ignore();
  }

  final int listenerId;
  final Future<void> Function(int listenerId) _closeFn;
  final _done = Completer<void>();
  late final StreamController<TailscaleConnection> _connections;
  final _pendingAccepts = Queue<_PendingTcpAccept>();
  ReceivePort? _acceptEvents;
  Isolate? _acceptIsolate;
  bool _closed = false;

  @override
  final TailscaleEndpoint local;

  @override
  Stream<TailscaleConnection> get connections => _connections.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return done;
    _closed = true;
    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await _closeFn(listenerId);
    } catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    } finally {
      _acceptIsolate?.kill(priority: Isolate.immediate);
      _acceptEvents?.close();
      _closePendingAccepts();
      if (!_connections.isClosed) unawaited(_connections.close());
    }
    if (closeError != null) {
      if (!_done.isCompleted) {
        _done.completeError(closeError, closeStackTrace);
      }
      Error.throwWithStackTrace(
        closeError,
        closeStackTrace ?? StackTrace.current,
      );
    }
    if (!_done.isCompleted) _done.complete();
    return done;
  }

  void _startAcceptLoop() {
    if (_closed || _acceptEvents != null) return;
    final events = ReceivePort();
    _acceptEvents = events;
    events.listen(_handleAcceptEvent);
    unawaited(() async {
      try {
        _acceptIsolate = await Isolate.spawn(_tcpAcceptLoop, <Object>[
          listenerId,
          events.sendPort,
        ], debugName: 'tailscale-tcp-accept-$listenerId');
        // If the loop isolate ever dies without sending a terminal message,
        // its exit posts null to the events port, which routes to close() — so
        // the listener can't hang forever awaiting a dead accept isolate.
        _acceptIsolate!.addOnExitListener(events.sendPort);
      } catch (error, stackTrace) {
        if (!_connections.isClosed) {
          _connections.addError(error, stackTrace);
          await close();
        }
      }
    }());
  }

  void _handleAcceptEvent(Object? message) {
    if (_closed) {
      // Release any fd carried by an in-flight 'accepted' message that arrived
      // after close; otherwise the descriptor (and its live tailnet
      // connection) leaks until process exit.
      if (message is List &&
          message.length == 7 &&
          message[0] == 'accepted' &&
          message[1] is int) {
        closePosixFdForCleanup(message[1] as int);
      }
      return;
    }
    if (message == null) {
      unawaited(close());
      return;
    }
    if (message is List && message.isNotEmpty && message[0] == 'error') {
      final detail = message.length > 1 ? message[1] : 'unknown error';
      _connections.addError(TailscaleTcpException('$detail'));
      return;
    }
    if (message is List && message.isNotEmpty && message[0] == 'fatal') {
      final detail = message.length > 1 ? message[1] : 'unknown error';
      _connections.addError(TailscaleTcpException('$detail'));
      unawaited(close());
      return;
    }
    if (message is! List || message.length != 7 || message[0] != 'accepted') {
      return;
    }
    final fd = message[1] as int;
    final local = TailscaleEndpoint(
      address: message[2] as String,
      port: message[3] as int,
    );
    final remote = TailscaleEndpoint(
      address: message[4] as String,
      port: message[5] as int,
    );
    final identity = message[6] as TailscaleNodeIdentity?;
    final accept = _PendingTcpAccept(
      fd: fd,
      local: local,
      remote: remote,
      identity: identity,
    );
    if (_connections.isPaused || _pendingAccepts.isNotEmpty) {
      _enqueueAccepted(accept);
      return;
    }
    _deliverAccepted(accept);
  }

  void _enqueueAccepted(_PendingTcpAccept accept) {
    if (_pendingAccepts.length >= _maxPendingAcceptedConnections) {
      accept.close();
      return;
    }
    _pendingAccepts.addLast(accept);
  }

  void _drainPendingAccepts() {
    while (!_closed && !_connections.isPaused && _pendingAccepts.isNotEmpty) {
      _deliverAccepted(_pendingAccepts.removeFirst());
    }
  }

  void _deliverAccepted(_PendingTcpAccept accept) {
    unawaited(() async {
      try {
        final connection = await createFdTailscaleConnection(
          fd: accept.fd,
          local: accept.local,
          remote: accept.remote,
          identity: accept.identity,
        );
        if (_closed || _connections.isClosed) {
          await connection.close();
          return;
        }
        _connections.add(connection);
      } catch (error, stackTrace) {
        _connections.addError(error, stackTrace);
      }
    }());
  }

  void _closePendingAccepts() {
    for (final accept in _pendingAccepts) {
      accept.close();
    }
    _pendingAccepts.clear();
  }
}

final class _PendingTcpAccept {
  const _PendingTcpAccept({
    required this.fd,
    required this.local,
    required this.remote,
    required this.identity,
  });

  final int fd;
  final TailscaleEndpoint local;
  final TailscaleEndpoint remote;
  final TailscaleNodeIdentity? identity;

  void close() {
    closePosixFdForCleanup(fd);
  }
}

void _tcpAcceptLoop(List<Object> args) {
  final listenerId = args[0] as int;
  final sendPort = args[1] as SendPort;
  var consecutiveErrors = 0;

  try {
    while (true) {
      final resultPtr = native.duneTcpAcceptFd(listenerId);
      final String resultJson;
      try {
        resultJson = resultPtr.toDartString();
      } finally {
        native.duneFree(resultPtr);
      }

      final decoded = jsonDecode(resultJson);
      if (decoded is! Map<String, dynamic>) {
        sendPort.send(<Object>[
          'fatal',
          'native accept returned malformed result',
        ]);
        return;
      }
      final result = decoded;
      if (result['closed'] == true) {
        sendPort.send(null);
        return;
      }
      final error = result['error'] as String?;
      if (error != null) {
        consecutiveErrors++;
        if (consecutiveErrors >= _maxConsecutiveAcceptErrors) {
          sendPort.send(<Object>[
            'fatal',
            'tailnet accept failed $consecutiveErrors consecutive times: $error',
          ]);
          return;
        }
        sendPort.send(<Object>['error', error]);
        sleep(Duration(milliseconds: 50 * consecutiveErrors));
        continue;
      }
      consecutiveErrors = 0;

      final fd = result['fd'] as int?;
      if (fd == null || fd < 0) {
        sendPort.send(<Object>['fatal', 'native accept returned invalid fd']);
        return;
      }
      // Identity is attached by the backend at accept time when the remote
      // IP resolves to a known node; absent otherwise. Decode it here so the
      // immutable value crosses the isolate boundary already typed.
      final identityJson = result['identity'];
      final identity = identityJson is Map<String, dynamic>
          ? TailscaleNodeIdentity.fromJson(identityJson)
          : null;
      sendPort.send(<Object?>[
        'accepted',
        fd,
        result['localAddress'] as String? ?? '',
        result['localPort'] as int? ?? 0,
        result['remoteAddress'] as String? ?? '',
        result['remotePort'] as int? ?? 0,
        identity,
      ]);
    }
  } catch (error) {
    // A malformed native result or any other unexpected throw would otherwise
    // kill this isolate silently and hang the parent's accept stream. Surface
    // it as a terminal 'fatal' so the parent errors out and closes.
    sendPort.send(<Object>['fatal', 'tailnet accept loop crashed: $error']);
  }
}
