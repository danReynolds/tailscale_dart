import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'runtime_transport_delegate.dart';
import 'transport.dart';

const _transportProtocolVersion = 1;
const _transportInitialStreamCredit = 64 * 1024;
const _transportMaxDataPayload = 60 * 1024;
const _transportMaxDatagramPayload = 60 * 1024;
const _transportWriterQueueCap = 256;
const _transportListenerBacklogCap = 128;
const _transportDatagramQueueCap = 256;

const _transportFrameOpen = 1;
const _transportFrameData = 2;
const _transportFrameCredit = 3;
const _transportFrameFin = 4;
const _transportFrameRst = 5;
const _transportFrameBind = 6;
const _transportFrameDgram = 7;
const _transportFrameBindClose = 8;
const _transportFrameBindAbort = 9;
const _transportFrameGoAway = 10;
const _transportFrameSessionConfirm = 11;

final class RuntimeTransportBootstrap {
  const RuntimeTransportBootstrap({
    required this.masterSecretB64,
    required this.sessionGenerationIdB64,
    required this.preferredCarrierKind,
  });

  final String masterSecretB64;
  final String sessionGenerationIdB64;
  final String preferredCarrierKind;
}

final class RuntimeTransportSession {
  RuntimeTransportSession._({
    required RuntimeTransportBootstrap bootstrap,
    required RuntimeTransportDelegate worker,
    required void Function(TailscaleRuntimeError error) publishRuntimeError,
    required ServerSocket listener,
    required Socket socket,
    required this.listenerOwner,
    required Uint8List masterSecret,
    required Uint8List sessionGenerationId,
  }) : _bootstrap = bootstrap,
       _worker = worker,
       _publishRuntimeError = publishRuntimeError,
       _listener = listener,
       _socket = socket,
       _masterSecret = masterSecret,
       _sessionGenerationId = sessionGenerationId;

  final RuntimeTransportBootstrap _bootstrap;
  final RuntimeTransportDelegate _worker;
  final void Function(TailscaleRuntimeError error) _publishRuntimeError;
  final ServerSocket _listener;
  final Socket _socket;
  final String listenerOwner;
  final Uint8List _masterSecret;
  final Uint8List _sessionGenerationId;

  final Map<int, _ManagedConnection> _connections = <int, _ManagedConnection>{};
  final Map<int, Completer<_ManagedConnection>> _pendingDials =
      <int, Completer<_ManagedConnection>>{};
  final Map<int, _ManagedConnection> _orphanedOutboundOpens =
      <int, _ManagedConnection>{};
  final Map<int, _ManagedListener> _listeners = <int, _ManagedListener>{};
  final Map<int, _ManagedDatagramPort> _bindings =
      <int, _ManagedDatagramPort>{};
  final Map<int, Completer<_ManagedDatagramPort>> _pendingBindings =
      <int, Completer<_ManagedDatagramPort>>{};
  final Map<int, _ManagedDatagramPort> _orphanedBindings =
      <int, _ManagedDatagramPort>{};

  final Queue<_QueuedFrame> _sendQueue = ListQueue<_QueuedFrame>();
  final Queue<Completer<void>> _sendQueueWaiters = ListQueue<Completer<void>>();
  final _openCompleter = Completer<void>();
  final _doneCompleter = Completer<void>();

  late final Uint8List _dartToGoKey;
  late final Uint8List _goToDartKey;
  StreamIterator<List<int>>? _reader;

  Uint8List _bufferedRead = Uint8List(0);
  bool _sendLoopRunning = false;
  bool _closed = false;
  bool _closing = false;
  int _sendSeq = 0;
  int _recvSeq = 0;

  Future<void> get opened => _openCompleter.future;
  Future<void> get done => _doneCompleter.future;

  bool matchesBootstrap(RuntimeTransportBootstrap bootstrap) {
    return !_closed &&
        _bootstrap.masterSecretB64 == bootstrap.masterSecretB64 &&
        _bootstrap.sessionGenerationIdB64 == bootstrap.sessionGenerationIdB64 &&
        _bootstrap.preferredCarrierKind == bootstrap.preferredCarrierKind;
  }

  static Future<RuntimeTransportSession> start({
    required RuntimeTransportBootstrap bootstrap,
    required RuntimeTransportDelegate worker,
    required void Function(TailscaleRuntimeError error) publishRuntimeError,
    String listenerOwner = 'dart',
  }) async {
    final masterSecret = _decodeB64(bootstrap.masterSecretB64);
    final sessionGenerationId = _decodeB64(bootstrap.sessionGenerationIdB64);
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    final acceptor = StreamIterator<Socket>(listener);

    await worker.attachTransport(
      host: '127.0.0.1',
      port: listener.port,
      listenerOwner: listenerOwner,
    );

    try {
      final accepted = await acceptor.moveNext().timeout(
        const Duration(seconds: 10),
      );
      if (!accepted) {
        throw const TailscaleUpException(
          'Transport carrier closed before Go attached.',
        );
      }

      final session = RuntimeTransportSession._(
        bootstrap: bootstrap,
        worker: worker,
        publishRuntimeError: publishRuntimeError,
        listener: listener,
        socket: acceptor.current,
        listenerOwner: listenerOwner,
        masterSecret: masterSecret,
        sessionGenerationId: sessionGenerationId,
      );
      session._reader = StreamIterator<List<int>>(session._socket);
      await session
          ._completeHandshake(host: '127.0.0.1', port: listener.port)
          .timeout(const Duration(seconds: 10));
      session._openCompleter.complete();
      unawaited(session._readerLoop());
      return session;
    } finally {
      await acceptor.cancel();
    }
  }

  TailscaleListener registerListener(int port) {
    if (_closed || _closing) {
      throw const TailscaleTcpBindException(
        'Transport session is closing; no new listeners may be registered.',
      );
    }
    final existing = _listeners[port];
    if (existing != null) {
      return existing;
    }
    final listener = _ManagedListener._(
      port: port,
      onClose: () async {
        _listeners.remove(port);
        await _worker.tcpUnbind(port: port);
      },
    );
    _listeners[port] = listener;
    return listener;
  }

  Future<TailscaleConnection> dialTcp({
    required String host,
    required int port,
  }) async {
    if (_closed || _closing) {
      throw const TailscaleTcpDialException('Transport session is closed.');
    }
    final streamId = await _worker.tcpDial(host: host, port: port);
    final orphan = _orphanedOutboundOpens.remove(streamId);
    if (orphan != null) {
      return orphan;
    }
    final completer = Completer<_ManagedConnection>();
    _pendingDials[streamId] = completer;
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      _pendingDials.remove(streamId);
    }
  }

  Future<TailscaleDatagramPort> bindUdp({required int port}) async {
    if (_closed || _closing) {
      throw const TailscaleUdpBindException(
        'Transport session is closing; no new datagram bindings may be created.',
      );
    }
    final bindingId = await _worker.udpBind(port: port);
    final orphan = _orphanedBindings.remove(bindingId);
    if (orphan != null) {
      return orphan;
    }
    final completer = Completer<_ManagedDatagramPort>();
    _pendingBindings[bindingId] = completer;
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      _pendingBindings.remove(bindingId);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _closing = true;
    _wakeSendQueueWaiters();
    try {
      await _listener.close();
    } catch (_) {}
    try {
      await _reader?.cancel();
    } catch (_) {}
    try {
      await _socket.close();
    } catch (_) {
      _socket.destroy();
    }
    _failAll(
      const TailscaleRuntimeError(
        message: 'Transport session closed.',
        code: TailscaleRuntimeErrorCode.transport,
      ),
      publish: false,
    );
  }

  Future<void> sendData(int streamId, Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      final end = min(offset + _transportMaxDataPayload, bytes.length);
      final payload = BytesBuilder(copy: false)
        ..add(_u64(streamId))
        ..add(Uint8List.sublistView(bytes, offset, end));
      await _queueFrame(_transportFrameData, payload.takeBytes());
      offset = end;
    }
  }

  Future<void> sendFin(int streamId) =>
      _queueFrame(_transportFrameFin, _u64(streamId));

  Future<void> sendRst(int streamId) =>
      _queueFrame(_transportFrameRst, _u64(streamId));

  Future<void> sendCredit(int streamId, int credit) {
    final payload = BytesBuilder(copy: false)
      ..add(_u64(streamId))
      ..add(_u32(credit));
    return _queueFrame(_transportFrameCredit, payload.takeBytes());
  }

  Future<void> sendDatagram({
    required int bindingId,
    required TailscaleEndpoint remote,
    required Uint8List bytes,
  }) {
    final payload = jsonEncode(<String, Object?>{
      'bindingId': bindingId,
      'remote': <String, Object?>{'ip': remote.ip.address, 'port': remote.port},
      'dataB64': _encodeB64(bytes),
    });
    return _queueFrame(
      _transportFrameDgram,
      Uint8List.fromList(utf8.encode(payload)),
    );
  }

  Future<void> sendBindClose(int bindingId) =>
      _queueFrame(_transportFrameBindClose, _u64(bindingId));

  Future<void> sendBindAbort(int bindingId) =>
      _queueFrame(_transportFrameBindAbort, _u64(bindingId));

  Future<void> _completeHandshake({
    required String host,
    required int port,
  }) async {
    final clientHello = await _readLengthPrefixedJson();
    final listenerEndpoint = '$host:$port';
    final advertisedVersions = _decodeIntList(
      clientHello['sessionProtocolVersions'],
    );
    final requestedCapabilities = _decodeStringList(
      clientHello['requestedCapabilities'],
    );

    if (clientHello['type'] != 'CLIENT_HELLO') {
      throw TailscaleUpException(
        'Unexpected transport handshake message ${clientHello['type']}.',
      );
    }
    if (!advertisedVersions.contains(_transportProtocolVersion)) {
      throw TailscaleUpException(
        'No supported transport protocol version in $advertisedVersions.',
      );
    }
    if (requestedCapabilities.isNotEmpty) {
      throw TailscaleUpException(
        'Unsupported requested transport capabilities: $requestedCapabilities.',
      );
    }

    final clientHelloCanonical = _canonicalLines(<String, String>{
      'msg': 'CLIENT_HELLO',
      'session_protocol_versions': _canonicalIntList(advertisedVersions),
      'client_nonce_b64': clientHello['clientNonceB64'] as String,
      'session_generation_id_b64':
          clientHello['sessionGenerationIdB64'] as String,
      'carrier_kind': clientHello['carrierKind'] as String,
      'listener_owner': clientHello['listenerOwner'] as String,
      'listener_endpoint': clientHello['listenerEndpoint'] as String,
      'requested_capabilities': _canonicalStringList(requestedCapabilities),
    });
    if (clientHello['carrierKind'] != 'loopback_tcp' ||
        clientHello['listenerOwner'] != listenerOwner ||
        clientHello['listenerEndpoint'] != listenerEndpoint ||
        clientHello['sessionGenerationIdB64'] !=
            _bootstrap.sessionGenerationIdB64) {
      throw const TailscaleUpException(
        'Transport carrier binding did not match the expected bootstrap values.',
      );
    }

    final handshakeKey = _hkdfExtract(_sessionGenerationId, _masterSecret);
    final expectedClientMac = _hmacSha256(handshakeKey, clientHelloCanonical);
    final actualClientMac = _decodeB64(clientHello['macB64'] as String);
    if (!_equalBytes(expectedClientMac, actualClientMac)) {
      throw const TailscaleUpException('Transport handshake MAC mismatch.');
    }

    final serverNonce = _randomBytes(16);
    final serverHelloCanonical = _canonicalLines(<String, String>{
      'msg': 'SERVER_HELLO',
      'selected_version': '$_transportProtocolVersion',
      'client_nonce_b64': clientHello['clientNonceB64'] as String,
      'server_nonce_b64': _encodeB64(serverNonce),
      'session_generation_id_b64':
          clientHello['sessionGenerationIdB64'] as String,
      'carrier_kind': 'loopback_tcp',
      'listener_owner': listenerOwner,
      'listener_endpoint': listenerEndpoint,
      'accepted_capabilities': '',
    });
    final serverMac = _hmacSha256(
      handshakeKey,
      _appendWithNull(clientHelloCanonical, serverHelloCanonical),
    );
    await _writeLengthPrefixedJson(<String, Object?>{
      'type': 'SERVER_HELLO',
      'selectedVersion': _transportProtocolVersion,
      'serverNonceB64': _encodeB64(serverNonce),
      'sessionGenerationIdB64': _bootstrap.sessionGenerationIdB64,
      'carrierKind': 'loopback_tcp',
      'listenerOwner': listenerOwner,
      'listenerEndpoint': listenerEndpoint,
      'acceptedCapabilities': const <String>[],
      'macB64': _encodeB64(serverMac),
    });

    final transcriptHash = sha256.convert(
      _appendWithNull(clientHelloCanonical, serverHelloCanonical),
    );
    final sessionSecret = _hkdfExpand(
      handshakeKey,
      Uint8List.fromList(<int>[
        ...utf8.encode('tailscale_dart:v1:session'),
        ...transcriptHash.bytes,
      ]),
      32,
    );
    _dartToGoKey = _hkdfExpand(
      sessionSecret,
      Uint8List.fromList(utf8.encode('tailscale_dart:v1:dart_to_go_frame')),
      32,
    );
    _goToDartKey = _hkdfExpand(
      sessionSecret,
      Uint8List.fromList(utf8.encode('tailscale_dart:v1:go_to_dart_frame')),
      32,
    );
    await _readSessionConfirm();
  }

  Future<void> _readSessionConfirm() async {
    final header = await _readExact(16, timeout: const Duration(seconds: 10));
    if (header == null) {
      throw const TailscaleUpException(
        'Transport carrier closed before session confirmation.',
      );
    }
    if (header[0] != _transportProtocolVersion) {
      throw TailscaleUpException(
        'Transport frame version mismatch during session confirmation: ${header[0]}.',
      );
    }
    if (header[1] != _transportFrameSessionConfirm) {
      throw TailscaleUpException(
        'Expected SESSION_CONFIRM as first post-handshake frame, got kind ${header[1]}.',
      );
    }
    final sequence = _readU64(header, 4);
    if (sequence != 1) {
      throw TailscaleUpException(
        'Transport session confirmation sequence mismatch: got $sequence expected 1.',
      );
    }
    final payloadLength = _readU32(header, 12);
    if (payloadLength != 0) {
      throw TailscaleUpException(
        'SESSION_CONFIRM carried unexpected payload length $payloadLength.',
      );
    }
    final mac = await _readExact(32, timeout: const Duration(seconds: 10));
    if (mac == null) {
      throw const TailscaleUpException(
        'Transport carrier closed before session confirmation MAC.',
      );
    }
    final expectedMac = _hmacSha256(_goToDartKey, header);
    if (!_equalBytes(expectedMac, mac)) {
      throw const TailscaleUpException(
        'Transport session confirmation MAC mismatch.',
      );
    }
    _recvSeq = sequence;
  }

  Future<void> _readerLoop() async {
    try {
      while (!_closed) {
        final header = await _readExact(16);
        if (header == null) {
          break;
        }
        final payloadLength = _readU32(header, 12);
        final payload = await _readExact(payloadLength);
        final mac = await _readExact(32);
        if (payload == null || mac == null) {
          throw const TailscaleUpException(
            'Transport carrier closed unexpectedly while reading a frame.',
          );
        }

        final sequence = _readU64(header, 4);
        if (sequence != _recvSeq + 1) {
          throw TailscaleUpException(
            'Transport frame sequence mismatch: got $sequence expected ${_recvSeq + 1}.',
          );
        }
        final expectedMac = _hmacSha256(
          _goToDartKey,
          Uint8List.fromList(<int>[...header, ...payload]),
        );
        if (!_equalBytes(expectedMac, mac)) {
          throw const TailscaleUpException('Transport frame MAC mismatch.');
        }
        _recvSeq = sequence;
        await _handleFrame(header[1], payload);
      }
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    } catch (error, stackTrace) {
      final runtimeError = TailscaleRuntimeError(
        message: error.toString(),
        code: TailscaleRuntimeErrorCode.transport,
      );
      _failAll(runtimeError);
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _handleFrame(int kind, Uint8List payload) async {
    switch (kind) {
      case _transportFrameOpen:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final connection = _ManagedConnection.fromOpen(
          session: this,
          json: decoded.cast<String, dynamic>(),
        );
        _connections[connection.streamId] = connection;
        if (connection.streamId.isOdd) {
          final pending = _pendingDials.remove(connection.streamId);
          if (pending != null) {
            pending.complete(connection);
          } else {
            _orphanedOutboundOpens[connection.streamId] = connection;
          }
          return;
        }
        final listener = _listeners[connection.local.port];
        if (listener == null || !listener.enqueue(connection)) {
          await sendRst(connection.streamId);
          connection._markReset(
            const TailscaleTcpBindException(
              'Inbound connection rejected because no Dart listener could accept it.',
            ),
          );
          _connections.remove(connection.streamId);
        }
        return;
      case _transportFrameData:
        final streamId = _readU64(payload, 0);
        final connection = _connections[streamId];
        if (connection == null) {
          throw TailscaleUpException(
            'Transport DATA arrived before OPEN for stream $streamId.',
          );
        }
        final bytes = Uint8List.sublistView(payload, 8);
        connection._addInput(bytes);
        await sendCredit(streamId, bytes.length);
        return;
      case _transportFrameCredit:
        final streamId = _readU64(payload, 0);
        final credit = _readU32(payload, 8);
        _connections[streamId]?._grantCredit(credit);
        return;
      case _transportFrameFin:
        final streamId = _readU64(payload, 0);
        final connection = _connections[streamId];
        if (connection == null) {
          throw TailscaleUpException(
            'Transport FIN arrived before OPEN for stream $streamId.',
          );
        }
        connection._markRemoteFin();
        return;
      case _transportFrameRst:
        final streamId = _readU64(payload, 0);
        final connection = _connections.remove(streamId);
        if (connection == null) {
          throw TailscaleUpException(
            'Transport RST arrived before OPEN for stream $streamId.',
          );
        }
        connection._markReset(
          const TailscaleTcpDialException('Transport stream reset by peer.'),
        );
        return;
      case _transportFrameBind:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final binding = _ManagedDatagramPort.fromBind(
          session: this,
          json: decoded.cast<String, dynamic>(),
        );
        _bindings[binding.bindingId] = binding;
        final pending = _pendingBindings.remove(binding.bindingId);
        if (pending != null) {
          pending.complete(binding);
        } else {
          _orphanedBindings[binding.bindingId] = binding;
        }
        return;
      case _transportFrameDgram:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final payloadJson = decoded.cast<String, dynamic>();
        final bindingId = payloadJson['bindingId'] as int;
        final binding = _bindings[bindingId];
        if (binding == null) {
          throw TailscaleOperationException(
            'udp',
            'Transport DGRAM arrived before BIND for binding $bindingId.',
          );
        }
        binding._addDatagram(
          TailscaleDatagram(
            bytes: _decodeB64(payloadJson['dataB64'] as String),
            local: binding.local,
            remote: _endpointFromJson(
              (payloadJson['remote'] as Map<Object?, Object?>)
                  .cast<String, dynamic>(),
            ),
            identity: payloadJson['identity'] == null
                ? null
                : _identityFromJson(
                    (payloadJson['identity'] as Map<Object?, Object?>)
                        .cast<String, dynamic>(),
                  ),
          ),
        );
        return;
      case _transportFrameBindClose:
        final bindingId = _readU64(payload, 0);
        final binding = _bindings.remove(bindingId);
        if (binding == null) {
          throw TailscaleOperationException(
            'udp',
            'Transport BIND_CLOSE arrived before BIND for binding $bindingId.',
          );
        }
        binding._markClosed();
        return;
      case _transportFrameBindAbort:
        final bindingId = _readU64(payload, 0);
        final binding = _bindings.remove(bindingId);
        if (binding == null) {
          throw TailscaleOperationException(
            'udp',
            'Transport BIND_ABORT arrived before BIND for binding $bindingId.',
          );
        }
        binding._markAborted(
          const TailscaleOperationException(
            'udp',
            'Transport datagram binding aborted by peer.',
          ),
        );
        return;
      case _transportFrameGoAway:
        _closing = true;
        if (!_openCompleter.isCompleted) {
          _openCompleter.complete();
        }
        return;
      case _transportFrameSessionConfirm:
        throw const TailscaleUpException(
          'Unexpected SESSION_CONFIRM after the transport session was already open.',
        );
      default:
        throw TailscaleUpException('Unexpected transport frame kind $kind.');
    }
  }

  Future<void> _queueFrame(int kind, List<int> payload) async {
    if (_closed) {
      throw const TailscaleUsageException('Transport session is closed.');
    }
    while (_sendQueue.length >= _transportWriterQueueCap) {
      final waiter = Completer<void>();
      _sendQueueWaiters.add(waiter);
      await waiter.future;
      if (_closed) {
        throw const TailscaleUsageException('Transport session is closed.');
      }
    }

    _sendQueue.add(
      _QueuedFrame(kind: kind, payload: Uint8List.fromList(payload)),
    );
    if (!_sendLoopRunning) {
      _sendLoopRunning = true;
      unawaited(_drainSendQueue());
    }
  }

  Future<void> _drainSendQueue() async {
    try {
      while (_sendQueue.isNotEmpty && !_closed) {
        final frame = _sendQueue.removeFirst();
        if (_sendQueueWaiters.isNotEmpty) {
          _sendQueueWaiters.removeFirst().complete();
        }
        _sendSeq += 1;
        final header = Uint8List(16);
        header[0] = _transportProtocolVersion;
        header[1] = frame.kind;
        _writeU64(header, 4, _sendSeq);
        _writeU32(header, 12, frame.payload.length);
        final mac = _hmacSha256(
          _dartToGoKey,
          Uint8List.fromList(<int>[...header, ...frame.payload]),
        );
        _socket.add(header);
        if (frame.payload.isNotEmpty) {
          _socket.add(frame.payload);
        }
        _socket.add(mac);
        await _socket.flush();
      }
    } catch (error) {
      final runtimeError = TailscaleRuntimeError(
        message: error.toString(),
        code: TailscaleRuntimeErrorCode.transport,
      );
      _failAll(runtimeError);
    } finally {
      _sendLoopRunning = false;
    }
  }

  Future<Map<String, dynamic>> _readLengthPrefixedJson() async {
    final header = await _readExact(4, timeout: const Duration(seconds: 10));
    if (header == null) {
      throw const TailscaleUpException(
        'Transport carrier closed before handshake completed.',
      );
    }
    final length = _readU32(header, 0);
    final payload = await _readExact(
      length,
      timeout: const Duration(seconds: 10),
    );
    if (payload == null) {
      throw const TailscaleUpException(
        'Transport carrier closed before handshake completed.',
      );
    }
    return (jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>)
        .cast<String, dynamic>();
  }

  Future<void> _writeLengthPrefixedJson(Map<String, Object?> value) async {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    _socket.add(_u32(payload.length));
    _socket.add(payload);
    await _socket.flush();
  }

  Future<Uint8List?> _readExact(int length, {Duration? timeout}) async {
    final buffer = BytesBuilder(copy: false);
    if (_bufferedRead.isNotEmpty) {
      if (_bufferedRead.length >= length) {
        final current = Uint8List.fromList(_bufferedRead.sublist(0, length));
        _bufferedRead = Uint8List.fromList(_bufferedRead.sublist(length));
        return current;
      }
      buffer.add(_bufferedRead);
      _bufferedRead = Uint8List(0);
    }
    while (buffer.length < length) {
      final moved = timeout == null
          ? await _reader!.moveNext()
          : await _reader!.moveNext().timeout(timeout);
      if (!moved) {
        if (buffer.length == 0) {
          return null;
        }
        throw const TailscaleUpException(
          'Unexpected EOF on transport carrier.',
        );
      }
      buffer.add(_reader!.current);
    }
    final bytes = buffer.takeBytes();
    final current = Uint8List.fromList(bytes.sublist(0, length));
    final overflow = bytes.sublist(length);
    _bufferedRead = overflow.isEmpty
        ? Uint8List(0)
        : Uint8List.fromList(overflow);
    return current;
  }

  void _failAll(TailscaleRuntimeError error, {bool publish = true}) {
    if (_closed) {
      return;
    }
    _closed = true;
    _closing = true;
    _wakeSendQueueWaiters();
    if (publish) {
      _publishRuntimeError(error);
    }
    if (!_openCompleter.isCompleted) {
      _openCompleter.completeError(TailscaleUpException(error.message));
    }
    for (final listener in _listeners.values.toList()) {
      listener._fail(error);
    }
    _listeners.clear();
    for (final completer in _pendingDials.values) {
      completer.completeError(TailscaleTcpDialException(error.message));
    }
    _pendingDials.clear();
    for (final connection in _orphanedOutboundOpens.values) {
      connection._markReset(TailscaleTcpDialException(error.message));
    }
    _orphanedOutboundOpens.clear();
    for (final connection in _connections.values) {
      connection._markReset(TailscaleTcpDialException(error.message));
    }
    _connections.clear();
    for (final completer in _pendingBindings.values) {
      completer.completeError(TailscaleUdpBindException(error.message));
    }
    _pendingBindings.clear();
    for (final binding in _orphanedBindings.values) {
      binding._markAborted(TailscaleOperationException('udp', error.message));
    }
    _orphanedBindings.clear();
    for (final binding in _bindings.values) {
      binding._markAborted(TailscaleOperationException('udp', error.message));
    }
    _bindings.clear();
  }

  void _wakeSendQueueWaiters() {
    while (_sendQueueWaiters.isNotEmpty) {
      _sendQueueWaiters.removeFirst().complete();
    }
  }
}

final class _QueuedFrame {
  _QueuedFrame({required this.kind, required this.payload});

  final int kind;
  final Uint8List payload;
}

final class _ManagedListener implements TailscaleListener {
  _ManagedListener._({
    required this.port,
    required Future<void> Function() onClose,
  }) : _onClose = onClose {
    _controller = StreamController<TailscaleConnection>(
      onListen: _scheduleDrain,
      onPause: () => _paused = true,
      onResume: () {
        _paused = false;
        _scheduleDrain();
      },
      onCancel: () {
        _paused = true;
      },
    );
  }

  final int port;
  final Future<void> Function() _onClose;
  late final StreamController<TailscaleConnection> _controller;
  final ListQueue<TailscaleConnection> _pending =
      ListQueue<TailscaleConnection>();
  final Completer<void> _done = Completer<void>();

  bool _paused = false;
  bool _closed = false;
  bool _draining = false;

  @override
  Stream<TailscaleConnection> get connections => _controller.stream;

  @override
  Future<void> get done => _done.future;

  bool enqueue(TailscaleConnection connection) {
    if (_closed) {
      return false;
    }
    if (_pending.length >= _transportListenerBacklogCap) {
      return false;
    }
    _pending.add(connection);
    _scheduleDrain();
    return true;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return _done.future;
    }
    _closed = true;
    await _onClose();
    await _controller.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _scheduleDrain() {
    if (_draining || _closed || !_controller.hasListener || _paused) {
      return;
    }
    _draining = true;
    scheduleMicrotask(() {
      _draining = false;
      while (_pending.isNotEmpty &&
          !_closed &&
          _controller.hasListener &&
          !_paused) {
        _controller.add(_pending.removeFirst());
      }
    });
  }

  void _fail(TailscaleRuntimeError error) {
    if (_closed) {
      return;
    }
    _closed = true;
    _controller.addError(error);
    unawaited(_controller.close());
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }
}

final class _ManagedConnection implements TailscaleConnection {
  _ManagedConnection._({
    required this.session,
    required this.streamId,
    required this.local,
    required this.remote,
    required this.identity,
  }) : _output = _ManagedWriter._();

  factory _ManagedConnection.fromOpen({
    required RuntimeTransportSession session,
    required Map<String, dynamic> json,
  }) {
    final local = _endpointFromJson(
      (json['local'] as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    final remote = _endpointFromJson(
      (json['remote'] as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    final identityJson = json['identity'];
    final identity = identityJson == null
        ? null
        : _identityFromJson(
            (identityJson as Map<Object?, Object?>).cast<String, dynamic>(),
          );
    final connection = _ManagedConnection._(
      session: session,
      streamId: json['streamId'] as int,
      local: local,
      remote: remote,
      identity: identity,
    );
    connection._output._attach(connection);
    return connection;
  }

  final RuntimeTransportSession session;
  final int streamId;
  @override
  final TailscaleEndpoint local;
  @override
  final TailscaleEndpoint remote;
  @override
  final TailscaleIdentity? identity;

  final StreamController<Uint8List> _inputController =
      StreamController<Uint8List>();
  final _ManagedWriter _output;
  final Completer<void> _done = Completer<void>();

  Completer<void>? _creditWaiter;
  int _outboundCredit = _transportInitialStreamCredit;
  bool _localWriteClosed = false;
  bool _remoteFin = false;
  bool _reset = false;
  bool _discardInput = false;

  @override
  Stream<Uint8List> get input => _inputController.stream;

  @override
  TailscaleWriter get output => _output;

  @override
  Future<void> get done => _done.future;

  Future<void> _write(Uint8List bytes) async {
    if (_localWriteClosed) {
      throw const TailscaleUsageException('Write half is already closed.');
    }
    var offset = 0;
    while (offset < bytes.length) {
      while (_outboundCredit <= 0 && !_reset) {
        _creditWaiter ??= Completer<void>();
        await _creditWaiter!.future;
      }
      if (_reset) {
        throw const TailscaleTcpDialException(
          'Transport stream has been reset.',
        );
      }
      final allowed = min(
        min(bytes.length - offset, _transportMaxDataPayload),
        _outboundCredit,
      );
      _outboundCredit -= allowed;
      await session.sendData(
        streamId,
        Uint8List.sublistView(bytes, offset, offset + allowed),
      );
      offset += allowed;
    }
  }

  Future<void> _writeAll(Stream<List<int>> source) async {
    await for (final chunk in source) {
      await _write(Uint8List.fromList(chunk));
    }
  }

  Future<void> _closeWrite() async {
    if (_localWriteClosed) {
      return _output.done;
    }
    await session.sendFin(streamId);
    _localWriteClosed = true;
    _output._complete();
    _checkDone();
  }

  void _grantCredit(int credit) {
    _outboundCredit += credit;
    final waiter = _creditWaiter;
    _creditWaiter = null;
    waiter?.complete();
  }

  void _addInput(Uint8List bytes) {
    if (_reset) {
      return;
    }
    if (_discardInput) {
      return;
    }
    _inputController.add(Uint8List.fromList(bytes));
  }

  void _markRemoteFin() {
    _remoteFin = true;
    if (!_inputController.isClosed) {
      unawaited(_inputController.close());
    }
    _checkDone();
  }

  void _markReset(TailscaleException error) {
    if (_reset) {
      return;
    }
    _reset = true;
    _creditWaiter?.complete();
    _creditWaiter = null;
    if (!_inputController.isClosed) {
      _inputController.addError(error);
      unawaited(_inputController.close());
    }
    _output._fail(error);
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }

  void _checkDone() {
    if (_reset || _done.isCompleted) {
      return;
    }
    if (_localWriteClosed && _remoteFin) {
      _done.complete();
    }
  }

  @override
  Future<void> close() async {
    _discardInput = true;
    if (!_localWriteClosed) {
      await _closeWrite();
    }
    if (_remoteFin && !_done.isCompleted) {
      _done.complete();
    }
    await _done.future;
  }

  @override
  void abort([Object? error, StackTrace? stackTrace]) {
    if (_reset) {
      return;
    }
    unawaited(session.sendRst(streamId));
    _markReset(
      TailscaleTcpDialException(
        error?.toString() ?? 'Transport stream aborted by caller.',
      ),
    );
  }
}

final class _ManagedWriter implements TailscaleWriter {
  _ManagedWriter._();

  _ManagedConnection? _connection;
  final Completer<void> _done = Completer<void>();

  void _attach(_ManagedConnection connection) {
    _connection = connection;
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() => _connection!._closeWrite();

  @override
  Future<void> write(Uint8List bytes) => _connection!._write(bytes);

  @override
  Future<void> writeAll(Stream<List<int>> source) =>
      _connection!._writeAll(source);

  void _complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _fail(TailscaleException error) {
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }
}

final class _ManagedDatagramPort implements TailscaleDatagramPort {
  _ManagedDatagramPort._({
    required this.session,
    required this.bindingId,
    required this.local,
  }) {
    _datagramController = StreamController<TailscaleDatagram>(
      onListen: _scheduleDatagramDrain,
      onResume: _scheduleDatagramDrain,
    );
  }

  factory _ManagedDatagramPort.fromBind({
    required RuntimeTransportSession session,
    required Map<String, dynamic> json,
  }) {
    return _ManagedDatagramPort._(
      session: session,
      bindingId: json['bindingId'] as int,
      local: _endpointFromJson(
        (json['local'] as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );
  }

  final RuntimeTransportSession session;
  final int bindingId;

  @override
  final TailscaleEndpoint local;

  late final StreamController<TailscaleDatagram> _datagramController;
  final Completer<void> _done = Completer<void>();

  bool _closed = false;
  bool _aborted = false;

  @override
  Stream<TailscaleDatagram> get datagrams => _datagramController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(
    Uint8List bytes, {
    required TailscaleEndpoint remote,
  }) async {
    if (_closed || _aborted) {
      throw const TailscaleUsageException(
        'Datagram binding is already closed.',
      );
    }
    if (bytes.length > _transportMaxDatagramPayload) {
      throw TailscaleOperationException(
        'udp.send',
        'Datagram too large: ${bytes.length} bytes exceeds the 60 KiB v1 limit.',
      );
    }
    await session.sendDatagram(
      bindingId: bindingId,
      remote: remote,
      bytes: bytes,
    );
  }

  void _addDatagram(TailscaleDatagram datagram) {
    if (_closed || _aborted) {
      return;
    }
    if (_pendingDatagrams.length >= _transportDatagramQueueCap) {
      return;
    }
    _pendingDatagrams.add(datagram);
    _scheduleDatagramDrain();
  }

  final ListQueue<TailscaleDatagram> _pendingDatagrams =
      ListQueue<TailscaleDatagram>();
  bool _draining = false;

  void _scheduleDatagramDrain() {
    if (_draining || _closed || !_datagramController.hasListener) {
      return;
    }
    _draining = true;
    scheduleMicrotask(() {
      _draining = false;
      while (_pendingDatagrams.isNotEmpty &&
          !_closed &&
          _datagramController.hasListener &&
          !_datagramController.isPaused) {
        _datagramController.add(_pendingDatagrams.removeFirst());
      }
    });
  }

  void _markClosed() {
    if (_closed || _aborted) {
      return;
    }
    _closed = true;
    _pendingDatagrams.clear();
    unawaited(_datagramController.close());
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _markAborted(TailscaleException error) {
    if (_aborted) {
      return;
    }
    _aborted = true;
    _closed = true;
    _pendingDatagrams.clear();
    if (!_datagramController.isClosed) {
      _datagramController.addError(error);
      unawaited(_datagramController.close());
    }
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }

  @override
  Future<void> close() async {
    if (_closed || _aborted) {
      return _done.future;
    }
    session._bindings.remove(bindingId);
    session._orphanedBindings.remove(bindingId);
    await session.sendBindClose(bindingId);
    _markClosed();
  }

  @override
  void abort([Object? error, StackTrace? stackTrace]) {
    if (_aborted) {
      return;
    }
    session._bindings.remove(bindingId);
    session._orphanedBindings.remove(bindingId);
    unawaited(session.sendBindAbort(bindingId));
    _markAborted(
      TailscaleOperationException(
        'udp',
        error?.toString() ?? 'Datagram binding aborted by caller.',
        cause: stackTrace,
      ),
    );
  }
}

TailscaleEndpoint _endpointFromJson(Map<String, dynamic> json) {
  final ipText = json['ip'] as String;
  final address = InternetAddress.tryParse(ipText);
  if (address == null) {
    throw TailscaleOperationException(
      'transport',
      'Native transport returned a non-IP endpoint: $ipText',
    );
  }
  return TailscaleEndpoint(ip: address, port: json['port'] as int);
}

TailscaleIdentity _identityFromJson(Map<String, dynamic> json) {
  return TailscaleIdentity(
    stableNodeId: json['stableNodeId'] as String?,
    nodeName: json['nodeName'] as String?,
    userLogin: json['userLogin'] as String?,
    userDisplayName: json['userDisplayName'] as String?,
  );
}

Uint8List _u32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _u64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

void _writeU32(Uint8List target, int offset, int value) {
  ByteData.sublistView(target).setUint32(offset, value, Endian.big);
}

void _writeU64(Uint8List target, int offset, int value) {
  ByteData.sublistView(target).setUint64(offset, value, Endian.big);
}

int _readU32(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes).getUint32(offset, Endian.big);
}

int _readU64(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes).getUint64(offset, Endian.big);
}

Uint8List _decodeB64(String value) {
  final normalized = base64Url.normalize(value);
  return Uint8List.fromList(base64Url.decode(normalized));
}

String _encodeB64(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _hkdfExtract(List<int> salt, List<int> ikm) {
  return _hmacSha256(Uint8List.fromList(salt), Uint8List.fromList(ikm));
}

Uint8List _hkdfExpand(List<int> prk, List<int> info, int length) {
  final output = BytesBuilder(copy: false);
  var previous = Uint8List(0);
  var counter = 1;
  while (output.length < length) {
    final data = BytesBuilder(copy: false)
      ..add(previous)
      ..add(info)
      ..add(<int>[counter]);
    previous = _hmacSha256(Uint8List.fromList(prk), data.takeBytes());
    output.add(previous);
    counter += 1;
  }
  final bytes = output.takeBytes();
  return Uint8List.fromList(bytes.sublist(0, length));
}

Uint8List _hmacSha256(List<int> key, List<int> data) {
  final digest = Hmac(sha256, key).convert(data);
  return Uint8List.fromList(digest.bytes);
}

Uint8List _canonicalLines(Map<String, String> fields) {
  const order = <String>[
    'msg',
    'session_protocol_versions',
    'selected_version',
    'client_nonce_b64',
    'server_nonce_b64',
    'session_generation_id_b64',
    'carrier_kind',
    'listener_owner',
    'listener_endpoint',
    'requested_capabilities',
    'accepted_capabilities',
  ];
  final lines = <String>[];
  for (final key in order) {
    final value = fields[key];
    if (value == null) continue;
    lines.add('$key=$value');
  }
  return Uint8List.fromList(utf8.encode(lines.join('\n')));
}

List<int> _decodeIntList(Object? value) {
  final raw = value as List<dynamic>? ?? const <dynamic>[];
  return raw.map((item) => item as int).toList(growable: false);
}

List<String> _decodeStringList(Object? value) {
  final raw = value as List<dynamic>? ?? const <dynamic>[];
  return raw.map((item) => item as String).toList(growable: false);
}

String _canonicalIntList(List<int> values) => values.join(',');

String _canonicalStringList(List<String> values) {
  final sorted = List<String>.from(values)..sort();
  return sorted.join(',');
}

Uint8List _appendWithNull(List<int> left, List<int> right) {
  return Uint8List.fromList(<int>[...left, 0, ...right]);
}

bool _equalBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var index = 0; index < length; index++) {
    bytes[index] = random.nextInt(256);
  }
  return bytes;
}
