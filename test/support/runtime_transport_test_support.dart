import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tailscale/src/runtime_transport.dart';
import 'package:tailscale/src/runtime_transport_delegate.dart';

RuntimeTransportBootstrap runtimeTransportTestBootstrap() {
  return RuntimeTransportBootstrap(
    masterSecretB64: _encodeB64(_bytesOf(0x41, 32)),
    sessionGenerationIdB64: _encodeB64(_bytesOf(0x22, 16)),
    preferredCarrierKind: 'loopback_tcp',
  );
}

final class FakeRuntimeTransportDelegate implements RuntimeTransportDelegate {
  FakeRuntimeTransportDelegate({required this.onAttach});

  final Future<void> Function({
    required String host,
    required int port,
    required String listenerOwner,
  })
  onAttach;

  @override
  Future<void> attachTransport({
    required String host,
    required int port,
    required String listenerOwner,
  }) async {
    unawaited(onAttach(host: host, port: port, listenerOwner: listenerOwner));
  }

  @override
  Future<int> tcpDial({required String host, required int port}) {
    throw UnimplementedError();
  }

  @override
  Future<void> tcpUnbind({required int port}) async {}

  @override
  Future<int> udpBind({required int port}) {
    throw UnimplementedError();
  }
}

final class FrameSpec {
  const FrameSpec({required this.kind, required this.payload});

  final int kind;
  final List<int> payload;
}

Future<void> performGoHandshake({
  required Socket socket,
  required RuntimeTransportBootstrap bootstrap,
  required String listenerOwner,
  Future<void> Function()? beforeConfirm,
  FrameSpec? firstFrameOverride,
  List<int> sessionVersions = const <int>[1],
  List<String> requestedCapabilities = const <String>[],
  bool skipConfirm = false,
}) async {
  final reader = _SocketReader(socket);
  final masterSecret = _decodeB64(bootstrap.masterSecretB64);
  final sessionGenerationId = _decodeB64(bootstrap.sessionGenerationIdB64);
  final clientNonce = _bytesOf(0x33, 16);
  final listenerEndpoint =
      '${socket.remoteAddress.address}:${socket.remotePort}';

  final handshakeKey = _hkdfExtract(sessionGenerationId, masterSecret);
  final clientHelloCanonical = _canonicalLines(<String, String>{
    'msg': 'CLIENT_HELLO',
    'session_protocol_versions': _canonicalIntList(sessionVersions),
    'client_nonce_b64': _encodeB64(clientNonce),
    'session_generation_id_b64': bootstrap.sessionGenerationIdB64,
    'carrier_kind': 'loopback_tcp',
    'listener_owner': listenerOwner,
    'listener_endpoint': listenerEndpoint,
    'requested_capabilities': _canonicalStringList(requestedCapabilities),
  });
  final clientHello = <String, Object?>{
    'type': 'CLIENT_HELLO',
    'sessionProtocolVersions': sessionVersions,
    'clientNonceB64': _encodeB64(clientNonce),
    'sessionGenerationIdB64': bootstrap.sessionGenerationIdB64,
    'carrierKind': 'loopback_tcp',
    'listenerOwner': listenerOwner,
    'listenerEndpoint': listenerEndpoint,
    'requestedCapabilities': requestedCapabilities,
    'macB64': _encodeB64(_hmacSha256(handshakeKey, clientHelloCanonical)),
  };
  await _writeLengthPrefixedJson(socket, clientHello);

  final serverHello = await _readLengthPrefixedJson(reader);
  final serverHelloCanonical = _canonicalLines(<String, String>{
    'msg': 'SERVER_HELLO',
    'selected_version': '${serverHello['selectedVersion'] as int}',
    'client_nonce_b64': clientHello['clientNonceB64'] as String,
    'server_nonce_b64': serverHello['serverNonceB64'] as String,
    'session_generation_id_b64':
        serverHello['sessionGenerationIdB64'] as String,
    'carrier_kind': serverHello['carrierKind'] as String,
    'listener_owner': serverHello['listenerOwner'] as String,
    'listener_endpoint': serverHello['listenerEndpoint'] as String,
    'accepted_capabilities': '',
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
  final goToDartKey = _hkdfExpand(
    sessionSecret,
    Uint8List.fromList(utf8.encode('tailscale_dart:v1:go_to_dart_frame')),
    32,
  );

  if (beforeConfirm != null) {
    await beforeConfirm();
  }

  if (skipConfirm) {
    return;
  }

  final frame =
      firstFrameOverride ?? const FrameSpec(kind: 11, payload: <int>[]);
  await _writeFramedMessage(
    socket: socket,
    key: goToDartKey,
    kind: frame.kind,
    sequence: 1,
    payload: Uint8List.fromList(frame.payload),
  );
}

Future<Map<String, dynamic>> _readLengthPrefixedJson(
  _SocketReader reader,
) async {
  final bytes = await reader.readExact(4);
  final length = _readU32(bytes, 0);
  final payload = await reader.readExact(length);
  return (jsonDecode(utf8.decode(payload)) as Map<Object?, Object?>)
      .cast<String, dynamic>();
}

Future<void> _writeLengthPrefixedJson(
  Socket socket,
  Map<String, Object?> value,
) async {
  final payload = Uint8List.fromList(utf8.encode(jsonEncode(value)));
  socket.add(_u32(payload.length));
  socket.add(payload);
  await socket.flush();
}

Future<void> _writeFramedMessage({
  required Socket socket,
  required Uint8List key,
  required int kind,
  required int sequence,
  required Uint8List payload,
}) async {
  final header = Uint8List(16);
  header[0] = 1;
  header[1] = kind;
  _writeU64(header, 4, sequence);
  _writeU32(header, 12, payload.length);
  final mac = _hmacSha256(
    key,
    Uint8List.fromList(<int>[...header, ...payload]),
  );
  socket.add(header);
  if (payload.isNotEmpty) {
    socket.add(payload);
  }
  socket.add(mac);
  await socket.flush();
}

final class _SocketReader {
  _SocketReader(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  Uint8List _buffer = Uint8List(0);

  Future<Uint8List> readExact(int length) async {
    while (_buffer.length < length) {
      final moved = await _iterator.moveNext();
      if (!moved) {
        throw StateError('Unexpected EOF.');
      }
      final next = _iterator.current;
      _buffer = Uint8List.fromList(<int>[..._buffer, ...next]);
    }

    final out = Uint8List.sublistView(_buffer, 0, length);
    _buffer = Uint8List.fromList(_buffer.sublist(length));
    return Uint8List.fromList(out);
  }
}

Uint8List _bytesOf(int value, int length) =>
    Uint8List.fromList(List<int>.filled(length, value));

String _encodeB64(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _decodeB64(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

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
    if (fields.containsKey(key)) {
      lines.add('$key=${fields[key] ?? ''}');
    }
  }
  return Uint8List.fromList(utf8.encode(lines.join('\n')));
}

String _canonicalIntList(List<int> values) => values.join(',');

String _canonicalStringList(List<String> values) {
  final sorted = List<String>.from(values)..sort();
  return sorted.join(',');
}

Uint8List _appendWithNull(Uint8List left, Uint8List right) =>
    Uint8List.fromList(<int>[...left, 0, ...right]);

Uint8List _hmacSha256(Uint8List key, Uint8List bytes) =>
    Uint8List.fromList(Hmac(sha256, key).convert(bytes).bytes);

Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) => _hmacSha256(salt, ikm);

Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  final output = BytesBuilder(copy: false);
  var previous = Uint8List(0);
  var counter = 1;
  while (output.length < length) {
    final blockInput = Uint8List.fromList(<int>[...previous, ...info, counter]);
    previous = _hmacSha256(prk, blockInput);
    output.add(previous);
    counter++;
  }
  final bytes = output.takeBytes();
  return Uint8List.sublistView(bytes, 0, length);
}

Uint8List _u32(int value) {
  final out = Uint8List(4);
  _writeU32(out, 0, value);
  return out;
}

void _writeU32(Uint8List buffer, int offset, int value) {
  final data = ByteData.sublistView(buffer);
  data.setUint32(offset, value, Endian.big);
}

void _writeU64(Uint8List buffer, int offset, int value) {
  final data = ByteData.sublistView(buffer);
  data.setUint64(offset, value, Endian.big);
}

int _readU32(Uint8List buffer, int offset) {
  final data = ByteData.sublistView(buffer);
  return data.getUint32(offset, Endian.big);
}
