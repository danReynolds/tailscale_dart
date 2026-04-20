import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../errors.dart';

typedef UdpBindFn = Future<int> Function(
  String tailnetHost,
  int tailnetPort,
  int loopbackPort,
);

/// UDP datagram sockets over the tailnet — tunneled over WireGuard
/// with the same direct-or-DERP fallback as TCP (see
/// <https://tailscale.com/kb/1257/connection-types>).
///
/// Reached via [Tailscale.udp].
abstract class Udp {
  /// Binds a UDP datagram socket on a specific tailnet IP of this
  /// node. Wraps `tsnet.Server.ListenPacket`.
  ///
  /// [host] is required and must be a valid tailnet address on this
  /// node — `tsnet.ListenPacket` does not accept a wildcard bind.
  /// Read one off `(await tsnet.status()).ipv4` or `.ipv6` at
  /// call time.
  ///
  /// [port] is the tailnet port to bind — pass `0` for an ephemeral
  /// port, then read it back from the returned [RawDatagramSocket.port].
  ///
  /// Implementation: Dart owns an ephemeral 127.0.0.1 TCP listener.
  /// The Go side opens the tsnet `PacketConn` and dials Dart's
  /// loopback. Each UDP datagram is carried as a framed record
  /// (`[addr-family|IP|port|len|payload]`) over that TCP control
  /// conn in both directions.
  ///
  /// The returned socket genuinely `implements RawDatagramSocket`.
  /// [RawDatagramSocket.receive] returns a [Datagram] whose
  /// [Datagram.address] is the real tailnet peer address (not a
  /// loopback stand-in), and [RawDatagramSocket.send] takes a
  /// tailnet address as the destination. The framing is not visible
  /// to callers.
  ///
  /// Caveats vs. a native UDP socket:
  /// - Multicast is not supported (`joinMulticast` / `leaveMulticast`
  ///   throw [UnsupportedError]).
  /// - Raw socket options (`getRawOption` / `setRawOption`) throw
  ///   [UnsupportedError].
  /// - Closing the socket tears down the tailnet listener.
  ///
  /// Note on co-residency: no per-bridge authentication on the
  /// loopback side. A co-resident process could connect to the
  /// ephemeral loopback port and send forged datagrams into the
  /// tailnet listener's Dart-side receive queue. If that matters
  /// for your threat model, add an application-level handshake.
  ///
  /// Throws [TailscaleUdpException] on setup failure — host isn't a
  /// valid IP, port is in use, loopback handshake fails, etc.
  Future<RawDatagramSocket> bind(String host, int port);
}

/// Library-internal factory. Reach via `Tailscale.instance.udp`.
@internal
Udp createUdp({required UdpBindFn bindFn}) => _Udp(bindFn);

final class _Udp implements Udp {
  _Udp(this._bind);

  final UdpBindFn _bind;

  @override
  Future<RawDatagramSocket> bind(String host, int port) async {
    if (host.isEmpty) {
      throw const TailscaleUdpException(
        'udp.bind requires a tailnet IP as host — wildcard binds are '
        'not supported by tsnet.ListenPacket.',
      );
    }
    final bound = InternetAddress.tryParse(host);
    if (bound == null) {
      throw TailscaleUdpException(
        'udp.bind: $host is not a valid IP address',
      );
    }

    final loopback = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final tailnetPortFuture = _bind(host, port, loopback.port);
    final bridgeFuture = loopback.first;

    try {
      // eagerError:true makes a Go-side bind failure surface
      // immediately instead of hanging on an accept that will
      // never happen.
      final results = await Future.wait(
        [tailnetPortFuture, bridgeFuture],
        eagerError: true,
      );
      final tailnetPort = results[0] as int;
      // Ownership passes to TailscaleUdpSocket below, which closes it
      // on teardown. The analyzer can't trace that hand-off.
      // ignore: close_sinks
      final bridge = results[1] as Socket;

      await loopback.close();

      return TailscaleUdpSocket(
        bound: bound,
        tailnetPort: tailnetPort,
        bridge: bridge,
      );
    } catch (e) {
      // With eagerError:true, Future.wait rethrows as soon as one
      // side fails. The other future may still complete later. Attach
      // fire-and-forget cleanup so a stray accept gets closed and any
      // lingering error is handled (not an unhandled async error).
      unawaited(
        bridgeFuture.then(
          (socket) => socket.destroy(),
          onError: (Object _) {
            // Expected: loopback was closed below before an accept
            // arrived. Nothing to clean up.
          },
        ),
      );
      unawaited(
        tailnetPortFuture.catchError((Object _) => 0),
      );
      try {
        await loopback.close();
      } catch (_) {
        // Loopback close errors are noise on the failure path.
      }
      if (e is TailscaleException) rethrow;
      throw TailscaleUdpException(
        'udp.bind failed for $host:$port',
        cause: e,
      );
    }
  }
}

/// `RawDatagramSocket` implementation backed by the framed TCP bridge
/// to the embedded Go runtime. Each accepted datagram's source
/// tailnet address is preserved in `Datagram.address`; `send` frames
/// the destination tailnet address into the bridge's outbound stream.
@visibleForTesting
class TailscaleUdpSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  TailscaleUdpSocket({
    required InternetAddress bound,
    required int tailnetPort,
    required Socket bridge,
  })  : _address = bound,
        _port = tailnetPort,
        _bridge = bridge {
    _bridge.listen(
      _onBridgeBytes,
      onError: (Object _, StackTrace __) => _teardown(),
      onDone: _teardown,
      cancelOnError: true,
    );
    scheduleMicrotask(() {
      if (!_closed && _writeEventsEnabled) {
        _events.add(RawSocketEvent.write);
      }
    });
  }

  final InternetAddress _address;
  final int _port;
  final Socket _bridge;
  final Queue<Datagram> _rx = Queue<Datagram>();

  // Parse buffer with an explicit cursor. Avoids the O(n²) copy loop
  // we'd get from toBytes()/clear/re-add on every parse iteration
  // when many frames are coalesced in one TCP chunk.
  Uint8List _parseBuf = Uint8List(0);
  int _parseCursor = 0;

  final StreamController<RawSocketEvent> _events =
      StreamController<RawSocketEvent>.broadcast();
  bool _closed = false;
  bool _readEventsEnabled = true;
  bool _writeEventsEnabled = true;

  @override
  InternetAddress get address => _address;

  @override
  int get port => _port;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _events.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  void _onBridgeBytes(Uint8List chunk) {
    _appendToParseBuf(chunk);
    while (_tryParseOne()) {}
    _signalReadIfPending();
  }

  // Appends chunk to the parse buffer, keeping only the unparsed tail.
  // O(tail + chunk), not O(total buffered).
  void _appendToParseBuf(Uint8List chunk) {
    final tailStart = _parseCursor;
    final tailLen = _parseBuf.length - tailStart;
    final next = Uint8List(tailLen + chunk.length);
    if (tailLen > 0) {
      next.setRange(0, tailLen, _parseBuf, tailStart);
    }
    next.setRange(tailLen, next.length, chunk);
    _parseBuf = next;
    _parseCursor = 0;
  }

  /// Parses one frame out of [_parseBuf] starting at [_parseCursor].
  /// Returns true on success (cursor advanced), false if not enough
  /// bytes yet.
  bool _tryParseOne() {
    final available = _parseBuf.length - _parseCursor;
    if (available < 1) return false;

    final ipLen = _parseBuf[_parseCursor];
    if (ipLen != 4 && ipLen != 16) {
      // Go only ever emits 4 or 16. A bogus byte means the bridge
      // protocol is out of sync — fail fast rather than misread.
      _teardown();
      return false;
    }
    const headerSansIp = 1 + 2 + 2; // family byte + port + length
    final headerLen = headerSansIp + ipLen;
    if (available < headerLen) return false;

    final bd = ByteData.sublistView(_parseBuf);
    final peerPort = bd.getUint16(_parseCursor + 1 + ipLen);
    final payloadLen = bd.getUint16(_parseCursor + 1 + ipLen + 2);
    final totalLen = headerLen + payloadLen;
    if (available < totalLen) return false;

    // Copy both IP and payload out of the buffer — the Datagram
    // outlives the parse buffer (we keep only unparsed tails).
    final ipStart = _parseCursor + 1;
    final ip = _parseBuf.sublist(ipStart, ipStart + ipLen);
    final payloadStart = _parseCursor + headerLen;
    final payload = _parseBuf.sublist(payloadStart, payloadStart + payloadLen);

    _rx.add(Datagram(payload, InternetAddress.fromRawAddress(ip), peerPort));
    _parseCursor += totalLen;
    return true;
  }

  /// Emits a read event if we have datagrams buffered and read events
  /// are enabled. Safe to call after socket close — guards on state.
  void _signalReadIfPending() {
    if (_rx.isNotEmpty &&
        _readEventsEnabled &&
        !_closed &&
        !_events.isClosed) {
      _events.add(RawSocketEvent.read);
    }
  }

  @override
  Datagram? receive() {
    if (_rx.isEmpty) return null;
    final dg = _rx.removeFirst();
    // Re-trigger the read event if more datagrams are still buffered.
    // Without this, coalesced datagrams (multiple frames arriving in
    // a single TCP chunk) would get stranded until the next chunk
    // came in. Use a microtask so we don't fire re-entrantly inside
    // the caller's listener.
    if (_rx.isNotEmpty) {
      scheduleMicrotask(_signalReadIfPending);
    }
    return dg;
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (_closed) {
      throw const SocketException.closed();
    }
    final ipBytes = address.rawAddress;
    if (ipBytes.length != 4 && ipBytes.length != 16) {
      throw ArgumentError.value(
        address,
        'address',
        'unsupported address family (raw length ${ipBytes.length})',
      );
    }
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be 0..65535');
    }
    if (buffer.length > 65535) {
      throw ArgumentError.value(
        buffer.length,
        'buffer.length',
        'UDP payload exceeds 65535 bytes',
      );
    }

    final headerLen = 1 + ipBytes.length + 4;
    final frame = Uint8List(headerLen + buffer.length);
    frame[0] = ipBytes.length;
    frame.setRange(1, 1 + ipBytes.length, ipBytes);
    final bd = ByteData.sublistView(frame);
    bd.setUint16(1 + ipBytes.length, port);
    bd.setUint16(1 + ipBytes.length + 2, buffer.length);
    frame.setRange(headerLen, frame.length, buffer);

    _bridge.add(frame);
    return buffer.length;
  }

  void _teardown() {
    if (_closed) return;
    _closed = true;
    if (!_events.isClosed) {
      _events.add(RawSocketEvent.closed);
      unawaited(_events.close());
    }
    _bridge.destroy();
  }

  @override
  void close() => _teardown();

  // ─── Settings ─────────────────────────────────────────────────────
  @override
  bool broadcastEnabled = false;

  @override
  int multicastHops = 1;

  @override
  bool multicastLoopback = false;

  @override
  NetworkInterface? multicastInterface;

  @override
  bool get readEventsEnabled => _readEventsEnabled;
  @override
  set readEventsEnabled(bool value) {
    final wasOff = !_readEventsEnabled;
    _readEventsEnabled = value;
    if (wasOff && value) {
      scheduleMicrotask(_signalReadIfPending);
    }
  }

  @override
  bool get writeEventsEnabled => _writeEventsEnabled;
  @override
  set writeEventsEnabled(bool value) {
    final wasOff = !_writeEventsEnabled;
    _writeEventsEnabled = value;
    if (wasOff && value && !_closed) {
      // Match native RawDatagramSocket: re-enabling write events
      // signals the socket is writable (which, over our bridge, is
      // true as long as it's open).
      scheduleMicrotask(() {
        if (_writeEventsEnabled && !_closed && !_events.isClosed) {
          _events.add(RawSocketEvent.write);
        }
      });
    }
  }

  // ─── Multicast: not supported on the tailnet ──────────────────────
  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      throw UnsupportedError(
        'Multicast is not supported on tailnet UDP sockets.',
      );

  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      throw UnsupportedError(
        'Multicast is not supported on tailnet UDP sockets.',
      );

  // ─── Raw socket options: no passthrough over the bridge ──────────
  @override
  Uint8List getRawOption(RawSocketOption option) => throw UnsupportedError(
        'Raw socket options are not supported on tailnet UDP sockets.',
      );

  @override
  void setRawOption(RawSocketOption option) => throw UnsupportedError(
        'Raw socket options are not supported on tailnet UDP sockets.',
      );
}
