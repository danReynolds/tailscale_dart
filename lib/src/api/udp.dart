import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../_equality.dart';
import '../errors.dart';
import '../fd_transport.dart';
import 'connection.dart';
import 'identity.dart';

const int _udpEnvelopeVersion = 1;
const int _udpEnvelopeHeaderBytes = 4;

/// Maximum public UDP payload accepted by the v1 package-native transport.
const int tailscaleMaxDatagramPayloadBytes = 60 * 1024;

typedef UdpBindFn =
    Future<({int fd, TailscaleEndpoint local})> Function(String host, int port);
typedef UdpDefaultAddressFn = Future<String?> Function();

/// One UDP datagram received over the tailnet.
final class TailscaleDatagram {
  TailscaleDatagram({
    required this.remote,
    required List<int> payload,
    this.identity,
  }) : payload = Uint8List.fromList(payload);

  /// Remote tailnet endpoint that sent this datagram.
  final TailscaleEndpoint remote;

  /// Remote node identity, when the backend attached one.
  final TailscaleNodeIdentity? identity;

  /// Datagram payload. This is a copy owned by the receiver.
  final Uint8List payload;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleDatagram &&
          remote == other.remote &&
          identity == other.identity &&
          listEquals(payload, other.payload);

  @override
  int get hashCode => Object.hash(remote, identity, _bytesHash(payload));

  @override
  String toString() =>
      'TailscaleDatagram(remote: $remote, bytes: ${payload.length})';
}

/// UDP datagram binding over the tailnet.
abstract interface class TailscaleDatagramBinding {
  /// Local tailnet endpoint accepted by this binding.
  TailscaleEndpoint get local;

  /// Single-subscription stream of received datagrams.
  ///
  /// UDP has no backpressure guarantee. Datagrams received while there is no
  /// listener, or while the stream subscription is paused, may be dropped.
  Stream<TailscaleDatagram> get datagrams;

  /// Sends one datagram to [to].
  ///
  /// Completion means the datagram was accepted by the local transport, not
  /// that the remote node received or processed it. Payloads larger than
  /// [tailscaleMaxDatagramPayloadBytes] are rejected rather than fragmented.
  Future<void> send(List<int> payload, {required TailscaleEndpoint to});

  /// Closes this binding.
  Future<void> close();

  /// Completes when the binding is terminal.
  Future<void> get done;
}

/// UDP datagram sockets over the tailnet.
///
/// Reached via [Tailscale.udp].
abstract class Udp {
  /// Binds a UDP datagram endpoint on a tailnet IP of this node.
  ///
  /// When [address] is omitted, the node's current IPv4 tailnet address is
  /// used. Pass [address] to bind a specific local tailnet IP. Pass `0` for
  /// [port] to request an ephemeral local UDP port.
  Future<TailscaleDatagramBinding> bind({required int port, String? address});
}

/// Library-internal factory. Reach via `Tailscale.instance.udp`.
@internal
Udp createUdp({
  required UdpBindFn bindFn,
  required UdpDefaultAddressFn defaultAddressFn,
}) => _Udp(bindFn, defaultAddressFn);

@internal
Future<TailscaleDatagramBinding> createFdTailscaleDatagramBinding({
  required int fd,
  required TailscaleEndpoint local,
}) async {
  final transport = await PosixFdTransport.adopt(fd);
  return _FdTailscaleDatagramBinding(transport: transport, local: local);
}

final class _Udp implements Udp {
  const _Udp(this._bind, this._defaultAddress);

  final UdpBindFn _bind;
  final UdpDefaultAddressFn _defaultAddress;

  @override
  Future<TailscaleDatagramBinding> bind({
    required int port,
    String? address,
  }) async {
    if (Platform.isWindows) {
      throw const TailscaleUdpException('Windows is not supported.');
    }
    final resolvedAddress = address ?? await _defaultAddress();
    if (resolvedAddress == null || resolvedAddress.isEmpty) {
      throw const TailscaleUdpException(
        'udp.bind requires a local tailnet address before this node has IPv4.',
      );
    }
    try {
      final (:fd, :local) = await _bind(resolvedAddress, port);
      return createFdTailscaleDatagramBinding(fd: fd, local: local);
    } catch (e) {
      if (e is TailscaleUdpException) rethrow;
      throw TailscaleUdpException(
        'udp.bind failed for $resolvedAddress:$port',
        cause: e,
      );
    }
  }
}

final class _FdTailscaleDatagramBinding implements TailscaleDatagramBinding {
  _FdTailscaleDatagramBinding({
    required PosixFdTransport transport,
    required this.local,
  }) : _transport = transport {
    _datagrams = StreamController<TailscaleDatagram>(onCancel: close);
    _subscription = _transport.input.listen(
      _handleEnvelope,
      onError: _handleInputError,
      onDone: _handleInputDone,
      cancelOnError: true,
    );
    unawaited(
      _transport.done.then<void>(
        (_) => _completeDone(),
        onError: (Object error, StackTrace stackTrace) {
          _completeDone(error, stackTrace);
        },
      ),
    );
  }

  final PosixFdTransport _transport;
  late final StreamController<TailscaleDatagram> _datagrams;
  late final StreamSubscription<Uint8List> _subscription;
  final _done = Completer<void>();
  bool _closed = false;

  @override
  final TailscaleEndpoint local;

  @override
  Stream<TailscaleDatagram> get datagrams => _datagrams.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(List<int> payload, {required TailscaleEndpoint to}) async {
    if (_closed) throw const TailscaleUdpException('UDP binding is closed.');
    final envelope = _encodeDatagramEnvelope(to, payload);
    await _transport.write(envelope);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _transport.close();
    _closeDatagrams();
    _completeDone();
  }

  void _handleEnvelope(Uint8List envelope) {
    if (_closed || _datagrams.isClosed) return;
    if (!_datagrams.hasListener || _datagrams.isPaused) return;

    try {
      _datagrams.add(_decodeDatagramEnvelope(envelope));
    } catch (error, stackTrace) {
      _datagrams.addError(error, stackTrace);
    }
  }

  void _handleInputError(Object error, StackTrace stackTrace) {
    if (!_datagrams.isClosed) _datagrams.addError(error, stackTrace);
    _closeDatagrams();
    _completeDone(error, stackTrace);
  }

  void _handleInputDone() {
    _closeDatagrams();
    _completeDone();
  }

  void _closeDatagrams() {
    if (!_datagrams.isClosed) unawaited(_datagrams.close());
  }

  void _completeDone([Object? error, StackTrace? stackTrace]) {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error, stackTrace);
    }
  }
}

Uint8List _encodeDatagramEnvelope(TailscaleEndpoint remote, List<int> payload) {
  if (remote.address.isEmpty) {
    throw const TailscaleUdpException('remote address is required');
  }
  if (remote.port < 1 || remote.port > 65535) {
    throw TailscaleUdpException('invalid remote UDP port ${remote.port}');
  }
  if (payload.length > tailscaleMaxDatagramPayloadBytes) {
    throw TailscaleUdpException(
      'UDP payload exceeds $tailscaleMaxDatagramPayloadBytes bytes',
    );
  }

  final address = utf8.encode(remote.address);
  if (address.length > 255) {
    throw const TailscaleUdpException('remote address is too long');
  }

  final envelope = Uint8List(
    _udpEnvelopeHeaderBytes + address.length + payload.length,
  );
  envelope[0] = _udpEnvelopeVersion;
  envelope[1] = address.length;
  envelope[2] = (remote.port >> 8) & 0xff;
  envelope[3] = remote.port & 0xff;
  envelope.setRange(
    _udpEnvelopeHeaderBytes,
    _udpEnvelopeHeaderBytes + address.length,
    address,
  );
  envelope.setRange(
    _udpEnvelopeHeaderBytes + address.length,
    envelope.length,
    payload,
  );
  return envelope;
}

TailscaleDatagram _decodeDatagramEnvelope(Uint8List envelope) {
  if (envelope.length < _udpEnvelopeHeaderBytes) {
    throw const TailscaleUdpException('malformed UDP envelope');
  }
  if (envelope[0] != _udpEnvelopeVersion) {
    throw TailscaleUdpException(
      'unsupported UDP envelope version ${envelope[0]}',
    );
  }
  final addressLength = envelope[1];
  if (addressLength == 0) {
    throw const TailscaleUdpException('malformed UDP envelope address');
  }
  final payloadOffset = _udpEnvelopeHeaderBytes + addressLength;
  if (payloadOffset > envelope.length) {
    throw const TailscaleUdpException('malformed UDP envelope address');
  }
  final port = (envelope[2] << 8) | envelope[3];
  if (port < 1) {
    throw const TailscaleUdpException('malformed UDP envelope port');
  }
  final String address;
  try {
    address = utf8.decode(
      envelope.sublist(_udpEnvelopeHeaderBytes, payloadOffset),
    );
  } on FormatException catch (error) {
    throw TailscaleUdpException('malformed UDP envelope address', cause: error);
  }
  return TailscaleDatagram(
    remote: TailscaleEndpoint(address: address, port: port),
    payload: envelope.sublist(payloadOffset),
  );
}

int _bytesHash(List<int> bytes) {
  var hash = bytes.length;
  for (final byte in bytes) {
    hash = Object.hash(hash, byte);
  }
  return hash;
}
