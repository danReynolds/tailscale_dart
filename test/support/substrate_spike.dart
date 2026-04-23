import 'dart:ffi';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

const int spikeProtocolVersion = 1;
const int spikeInitialStreamCredit = 64 * 1024;
const int spikeMaxDataPayload = 60 * 1024;
const int spikeMaxDatagramPayload = 60 * 1024;
const int spikeOpenStreamCap = 1024;
const int spikeListenerBacklogLimit = 128;
const int spikeDatagramQueueLimit = 256;

const int _spikeFrameOpen = 1;
const int _spikeFrameData = 2;
const int _spikeFrameCredit = 3;
const int _spikeFrameFin = 4;
const int _spikeFrameRst = 5;
const int _spikeFrameBind = 6;
const int _spikeFrameDgram = 7;
const int _spikeFrameBindClose = 8;
const int _spikeFrameBindAbort = 9;
const int _spikeFrameGoAway = 10;

class SpikeClient {
  static void reset() {
    native.duneSpikeReset();
  }

  static Map<String, dynamic> bootstrap() =>
      _callJson0(native.duneSpikeBootstrap);

  static Map<String, dynamic> attach(Map<String, Object?> request) =>
      _callJson1(native.duneSpikeAttach, request);

  static Map<String, dynamic> command(String op, Map<String, Object?> args) =>
      _callJson1(native.duneSpikeCommand, {'op': op, 'args': args});

  static Map<String, dynamic> snapshot() =>
      _callJson0(native.duneSpikeSnapshot);

  static Future<Map<String, dynamic>> commandInIsolate(
    String op,
    Map<String, Object?> args,
  ) {
    return Isolate.run(() {
      return _callJson1(native.duneSpikeCommand, {'op': op, 'args': args});
    });
  }

  static Map<String, dynamic> _callJson0(Pointer<Utf8> Function() fn) {
    final ptr = fn();
    final jsonText = ptr.toDartString();
    native.duneFree(ptr);
    final decoded = jsonDecode(jsonText);
    if (decoded case {'error': String message}) {
      throw StateError(message);
    }
    return (decoded as Map<Object?, Object?>).cast<String, dynamic>();
  }

  static Map<String, dynamic> _callJson1(
    Pointer<Utf8> Function(Pointer<Utf8>) fn,
    Map<String, Object?> request,
  ) {
    final requestPtr = jsonEncode(request).toNativeUtf8();
    try {
      final ptr = fn(requestPtr);
      final jsonText = ptr.toDartString();
      native.duneFree(ptr);
      final decoded = jsonDecode(jsonText);
      if (decoded case {'error': String message}) {
        throw StateError(message);
      }
      return (decoded as Map<Object?, Object?>).cast<String, dynamic>();
    } finally {
      calloc.free(requestPtr);
    }
  }
}

class SpikeHarness {
  SpikeHarness._({
    required this.masterSecret,
    required this.sessionGenerationId,
    required this.listener,
    required Socket socket,
    required this.listenerOwner,
  }) : _socket = socket,
       _reader = StreamIterator<List<int>>(socket);

  final Uint8List masterSecret;
  final Uint8List sessionGenerationId;
  final ServerSocket listener;
  final String listenerOwner;

  final Socket _socket;
  final StreamIterator<List<int>> _reader;
  final Random _random = Random.secure();

  final List<SpikeOpenPayload> pendingConnections = <SpikeOpenPayload>[];
  final Map<int, HarnessStreamState> streams = <int, HarnessStreamState>{};
  final Map<int, HarnessBindingState> bindings = <int, HarnessBindingState>{};

  late final Uint8List _dartToGoKey;
  late final Uint8List _goToDartKey;

  bool goAwayReceived = false;
  int backlogDrops = 0;

  int _nextStreamId = 1;
  int _nextBindingId = 1;
  int _sendSeq = 0;
  int _recvSeq = 0;
  bool _closed = false;

  final Completer<void> _readerDone = Completer<void>();
  Uint8List _bufferedRead = Uint8List(0);
  Object? _readerError;
  StackTrace? _readerStackTrace;

  static Future<SpikeHarness> start({
    String listenerOwner = 'dart',
    String host = '127.0.0.1',
  }) async {
    SpikeClient.reset();
    final bootstrap = SpikeClient.bootstrap();
    final masterSecret = _decodeB64(bootstrap['masterSecretB64'] as String);
    final sessionGenerationId = _decodeB64(
      bootstrap['sessionGenerationIdB64'] as String,
    );

    final listener = await ServerSocket.bind(host, 0);
    final acceptor = StreamIterator<Socket>(listener);

    SpikeClient.attach({
      'carrierKind': 'loopback_tcp',
      'listenerOwner': listenerOwner,
      'host': host,
      'port': listener.port,
    });

    try {
      final accepted = await acceptor.moveNext().timeout(
        const Duration(seconds: 10),
      );
      if (!accepted) {
        throw StateError('Carrier listener closed before Go attached.');
      }
      // ignore: close_sinks
      final socket = acceptor.current;
      final harness = SpikeHarness._(
        masterSecret: masterSecret,
        sessionGenerationId: sessionGenerationId,
        listener: listener,
        socket: socket,
        listenerOwner: listenerOwner,
      );
      await harness._completeHandshake(host: host, port: listener.port);
      unawaited(harness._readerLoop());
      await harness.waitForCondition(
        () => SpikeClient.snapshot()['state'] == 'open',
      );
      return harness;
    } finally {
      await acceptor.cancel();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await listener.close();
    } catch (_) {}
    try {
      await _socket.close();
    } catch (_) {
      _socket.destroy();
    }
    try {
      await _reader.cancel();
    } catch (_) {}
    try {
      await _readerDone.future.timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  Future<void> waitForCondition(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!predicate()) {
      if (_readerError != null) {
        Error.throwWithStackTrace(_readerError!, _readerStackTrace!);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for spike condition.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<int> openStreamToGo({
    required String transport,
    required Map<String, Object?> local,
    required Map<String, Object?> remote,
    Map<String, Object?>? identity,
  }) async {
    final streamId = _nextStreamId;
    _nextStreamId += 2;
    final payload = jsonEncode({
      'streamId': streamId,
      'transport': transport,
      'local': local,
      'remote': remote,
      if (identity != null) 'identity': identity,
    });
    await _sendFrame(_spikeFrameOpen, utf8.encode(payload));
    return streamId;
  }

  Future<void> sendStreamDataToGo(int streamId, List<int> data) async {
    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + spikeMaxDataPayload, data.length);
      final payload = BytesBuilder(copy: false)
        ..add(_u64(streamId))
        ..add(data.sublist(offset, end));
      await _sendFrame(_spikeFrameData, payload.takeBytes());
      offset = end;
    }
  }

  Future<void> sendStreamFinToGo(int streamId) async {
    await _sendFrame(_spikeFrameFin, _u64(streamId));
  }

  Future<int> openBindingToGo({
    required String transport,
    required Map<String, Object?> local,
  }) async {
    final bindingId = _nextBindingId;
    _nextBindingId += 2;
    final payload = jsonEncode({
      'bindingId': bindingId,
      'transport': transport,
      'local': local,
    });
    await _sendFrame(_spikeFrameBind, utf8.encode(payload));
    return bindingId;
  }

  Future<void> sendDatagramToGo({
    required int bindingId,
    required Map<String, Object?> remote,
    required List<int> data,
    Map<String, Object?>? identity,
  }) async {
    if (data.length > spikeMaxDatagramPayload) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'Datagram too large',
      );
    }
    final payload = jsonEncode({
      'bindingId': bindingId,
      'remote': remote,
      'dataB64': _encodeB64(data),
      if (identity != null) 'identity': identity,
    });
    await _sendFrame(_spikeFrameDgram, utf8.encode(payload));
  }

  Future<void> grantCredit(int streamId, int credit) async {
    final payload = BytesBuilder(copy: false)
      ..add(_u64(streamId))
      ..add(_u32(credit));
    await _sendFrame(_spikeFrameCredit, payload.takeBytes());
  }

  Future<void> sendGoAway() async {
    await _sendFrame(_spikeFrameGoAway, Uint8List(0));
  }

  Future<void> _completeHandshake({
    required String host,
    required int port,
  }) async {
    final clientHello = await _readLengthPrefixedJson();
    final clientHelloCanonical = _canonicalLines(<String, String>{
      'msg': 'CLIENT_HELLO',
      'session_protocol_versions': '$spikeProtocolVersion',
      'client_nonce_b64': clientHello['clientNonceB64'] as String,
      'session_generation_id_b64':
          clientHello['sessionGenerationIdB64'] as String,
      'carrier_kind': clientHello['carrierKind'] as String,
      'listener_owner': clientHello['listenerOwner'] as String,
      'listener_endpoint': clientHello['listenerEndpoint'] as String,
      'requested_capabilities': '',
    });

    final handshakeKey = _hkdfExtract(sessionGenerationId, masterSecret);
    final listenerEndpoint = '$host:$port';
    if (clientHello['carrierKind'] != 'loopback_tcp' ||
        clientHello['listenerOwner'] != listenerOwner ||
        clientHello['listenerEndpoint'] != listenerEndpoint ||
        clientHello['sessionGenerationIdB64'] !=
            _encodeB64(sessionGenerationId)) {
      throw StateError('Unexpected client hello carrier binding.');
    }
    final expectedClientMac = _hmacSha256(handshakeKey, clientHelloCanonical);
    final actualClientMac = _decodeB64(clientHello['macB64'] as String);
    if (!_equalBytes(expectedClientMac, actualClientMac)) {
      throw StateError('Bad client hello MAC.');
    }

    final serverNonce = _randomBytes(16);
    final serverHelloCanonical = _canonicalLines(<String, String>{
      'msg': 'SERVER_HELLO',
      'selected_version': '$spikeProtocolVersion',
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
      'selectedVersion': spikeProtocolVersion,
      'serverNonceB64': _encodeB64(serverNonce),
      'sessionGenerationIdB64': _encodeB64(sessionGenerationId),
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
          throw StateError('Unexpected EOF while reading frame.');
        }

        final sequence = _readU64(header, 4);
        if (sequence != _recvSeq + 1) {
          throw StateError(
            'Unexpected sequence: got $sequence expected ${_recvSeq + 1}',
          );
        }
        final expectedMac = _hmacSha256(
          _goToDartKey,
          Uint8List.fromList(<int>[...header, ...payload]),
        );
        if (!_equalBytes(expectedMac, mac)) {
          throw StateError('Bad frame MAC.');
        }
        _recvSeq = sequence;
        await _handleFrame(header[1], payload);
      }
      if (!_readerDone.isCompleted) {
        _readerDone.complete();
      }
    } catch (error, stackTrace) {
      _readerError = error;
      _readerStackTrace = stackTrace;
      if (!_readerDone.isCompleted) {
        _readerDone.complete();
      }
    }
  }

  Future<void> _handleFrame(int kind, Uint8List payload) async {
    switch (kind) {
      case _spikeFrameOpen:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final open = SpikeOpenPayload.fromJson(decoded.cast<String, dynamic>());
        if (pendingConnections.length >= spikeListenerBacklogLimit) {
          backlogDrops++;
          await _sendFrame(_spikeFrameRst, _u64(open.streamId));
          return;
        }
        pendingConnections.add(open);
        streams[open.streamId] = HarnessStreamState();
        return;
      case _spikeFrameData:
        final streamId = _readU64(payload, 0);
        final state = streams[streamId];
        if (state == null) {
          throw StateError('DATA before OPEN for stream $streamId');
        }
        state.bytesReceived += payload.length - 8;
        return;
      case _spikeFrameFin:
        final streamId = _readU64(payload, 0);
        final state = streams[streamId];
        if (state == null) {
          throw StateError('FIN before OPEN for stream $streamId');
        }
        state.finReceived = true;
        return;
      case _spikeFrameRst:
        final streamId = _readU64(payload, 0);
        final state = streams[streamId];
        if (state == null) {
          throw StateError('RST before OPEN for stream $streamId');
        }
        state.rstReceived = true;
        state.bytesReceived = 0;
        return;
      case _spikeFrameBind:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final bind = SpikeBindPayload.fromJson(decoded.cast<String, dynamic>());
        bindings[bind.bindingId] = HarnessBindingState();
        return;
      case _spikeFrameDgram:
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>;
        final dgram = SpikeDgramPayload.fromJson(
          decoded.cast<String, dynamic>(),
        );
        final binding = bindings[dgram.bindingId];
        if (binding == null) {
          throw StateError('DGRAM before BIND for binding ${dgram.bindingId}');
        }
        if (binding.datagrams.length >= spikeDatagramQueueLimit) {
          binding.dropped++;
          return;
        }
        binding.datagrams.add(dgram);
        return;
      case _spikeFrameBindClose:
        final bindingId = _readU64(payload, 0);
        final binding = bindings[bindingId];
        if (binding == null) {
          throw StateError('BIND_CLOSE before BIND for binding $bindingId');
        }
        binding.closed = true;
        return;
      case _spikeFrameBindAbort:
        final bindingId = _readU64(payload, 0);
        final binding = bindings[bindingId];
        if (binding == null) {
          throw StateError('BIND_ABORT before BIND for binding $bindingId');
        }
        binding.aborted = true;
        binding.datagrams.clear();
        return;
      case _spikeFrameGoAway:
        goAwayReceived = true;
        return;
      default:
        throw StateError('Unexpected frame kind $kind');
    }
  }

  Future<void> _sendFrame(int kind, List<int> payload) async {
    final payloadBytes = Uint8List.fromList(payload);
    _sendSeq += 1;
    final header = Uint8List(16);
    header[0] = spikeProtocolVersion;
    header[1] = kind;
    _writeU64(header, 4, _sendSeq);
    _writeU32(header, 12, payloadBytes.length);
    final mac = _hmacSha256(
      _dartToGoKey,
      Uint8List.fromList(<int>[...header, ...payloadBytes]),
    );
    _socket.add(header);
    if (payloadBytes.isNotEmpty) {
      _socket.add(payloadBytes);
    }
    _socket.add(mac);
    await _socket.flush();
  }

  Future<Map<String, dynamic>> _readLengthPrefixedJson() async {
    final header = await _readExact(4);
    if (header == null) {
      throw StateError('Unexpected EOF reading handshake header.');
    }
    final length = _readU32(header, 0);
    final payload = await _readExact(length);
    if (payload == null) {
      throw StateError('Unexpected EOF reading handshake payload.');
    }
    final decoded = jsonDecode(utf8.decode(payload));
    return (decoded as Map<Object?, Object?>).cast<String, dynamic>();
  }

  Future<void> _writeLengthPrefixedJson(Map<String, Object?> value) async {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    final header = _u32(payload.length);
    _socket.add(header);
    _socket.add(payload);
    await _socket.flush();
  }

  Future<Uint8List?> _readExact(int length) async {
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
      final moved = await _reader.moveNext().timeout(
        const Duration(seconds: 5),
      );
      if (!moved) {
        if (buffer.length == 0) {
          return null;
        }
        throw StateError('Unexpected EOF while reading $length bytes.');
      }
      buffer.add(_reader.current);
    }
    final bytes = buffer.takeBytes();
    if (bytes.length < length) {
      throw StateError(
        'Short read: wanted $length bytes, got ${bytes.length}.',
      );
    }
    final current = Uint8List.fromList(bytes.sublist(0, length));
    final overflow = bytes.sublist(length);
    _bufferedRead = overflow.isEmpty
        ? Uint8List(0)
        : Uint8List.fromList(overflow);
    return current;
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}

class SpikeOpenPayload {
  SpikeOpenPayload({
    required this.streamId,
    required this.transport,
    required this.local,
    required this.remote,
    required this.identity,
  });

  factory SpikeOpenPayload.fromJson(Map<String, dynamic> json) {
    return SpikeOpenPayload(
      streamId: json['streamId'] as int,
      transport: json['transport'] as String,
      local: (json['local'] as Map<Object?, Object?>).cast<String, dynamic>(),
      remote: (json['remote'] as Map<Object?, Object?>).cast<String, dynamic>(),
      identity: json['identity'] == null
          ? null
          : (json['identity'] as Map<Object?, Object?>).cast<String, dynamic>(),
    );
  }

  final int streamId;
  final String transport;
  final Map<String, dynamic> local;
  final Map<String, dynamic> remote;
  final Map<String, dynamic>? identity;
}

class SpikeBindPayload {
  SpikeBindPayload({
    required this.bindingId,
    required this.transport,
    required this.local,
  });

  factory SpikeBindPayload.fromJson(Map<String, dynamic> json) {
    return SpikeBindPayload(
      bindingId: json['bindingId'] as int,
      transport: json['transport'] as String,
      local: (json['local'] as Map<Object?, Object?>).cast<String, dynamic>(),
    );
  }

  final int bindingId;
  final String transport;
  final Map<String, dynamic> local;
}

class SpikeDgramPayload {
  SpikeDgramPayload({
    required this.bindingId,
    required this.remote,
    required this.dataB64,
    required this.identity,
  });

  factory SpikeDgramPayload.fromJson(Map<String, dynamic> json) {
    return SpikeDgramPayload(
      bindingId: json['bindingId'] as int,
      remote: (json['remote'] as Map<Object?, Object?>).cast<String, dynamic>(),
      dataB64: json['dataB64'] as String,
      identity: json['identity'] == null
          ? null
          : (json['identity'] as Map<Object?, Object?>).cast<String, dynamic>(),
    );
  }

  final int bindingId;
  final Map<String, dynamic> remote;
  final String dataB64;
  final Map<String, dynamic>? identity;

  Uint8List get data => _decodeB64(dataB64);
}

class HarnessStreamState {
  int bytesReceived = 0;
  bool finReceived = false;
  bool rstReceived = false;
}

class HarnessBindingState {
  final List<SpikeDgramPayload> datagrams = <SpikeDgramPayload>[];
  int dropped = 0;
  bool closed = false;
  bool aborted = false;
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
