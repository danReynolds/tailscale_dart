/// Coverage for `TailscaleUdpSocket` — the `RawDatagramSocket`
/// implementation backed by the framed TCP bridge to Go.
///
/// Unit-level test: we create a real connected loopback TCP pair
/// (one end plays the Go side, the other is handed to the socket
/// under test) and verify framing in both directions without
/// needing a live tsnet runtime.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tailscale/src/api/udp.dart';

void main() {
  group('TailscaleUdpSocket framing', () {
    late ServerSocket server;
    late Socket goSide;
    // Handed to TailscaleUdpSocket which closes on tearDown via sock.close().
    // ignore: close_sinks
    late Socket dartSide;
    late TailscaleUdpSocket sock;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedFuture = server.first;
      dartSide = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      goSide = await acceptedFuture;
      await server.close();

      sock = TailscaleUdpSocket(
        bound: InternetAddress('100.64.0.5'),
        tailnetPort: 7000,
        bridge: dartSide,
      );
    });

    tearDown(() async {
      sock.close();
      try {
        goSide.destroy();
      } catch (_) {}
    });

    test('receive surfaces peer IP/port and payload from a framed IPv4 datagram',
        () async {
      final readEvent = sock.firstWhere((e) => e == RawSocketEvent.read);
      // Go side writes: addrFam=4, ip=100.64.0.7, port=9000, len=5, "hello"
      goSide.add(<int>[
        4, 100, 64, 0, 7, // afam + ip
        0x23, 0x28, // port 9000 BE
        0x00, 0x05, // len 5 BE
        ..._bytes('hello'),
      ]);
      await goSide.flush();

      await readEvent.timeout(const Duration(seconds: 2));
      final dg = sock.receive();
      expect(dg, isNotNull);
      expect(dg!.address.address, '100.64.0.7');
      expect(dg.port, 9000);
      expect(_str(dg.data), 'hello');
    });

    test('receive handles IPv6 peer address', () async {
      final readEvent = sock.firstWhere((e) => e == RawSocketEvent.read);
      final ip6 = InternetAddress('fd7a:115c:a1e0::5');
      final framed = <int>[
        16, ...ip6.rawAddress,
        0x04, 0xd2, // port 1234 BE
        0x00, 0x03, // len 3
        0xde, 0xad, 0xbe,
      ];

      goSide.add(framed);
      await goSide.flush();

      await readEvent.timeout(const Duration(seconds: 2));
      final dg = sock.receive();
      expect(dg, isNotNull);
      expect(dg!.address.address, ip6.address);
      expect(dg.port, 1234);
      expect(dg.data, Uint8List.fromList([0xde, 0xad, 0xbe]));
    });

    test('receive handles multiple frames coalesced into one chunk',
        () async {
      final framed = <int>[
        ..._frame('100.64.0.1', 1000, _bytes('a')),
        ..._frame('100.64.0.2', 2000, _bytes('bb')),
        ..._frame('100.64.0.3', 3000, _bytes('ccc')),
      ];
      goSide.add(framed);
      await goSide.flush();

      // Wait until the socket has buffered all three.
      await _pumpUntil(sock, () {
        var drained = <Datagram>[];
        Datagram? dg;
        while ((dg = sock.receive()) != null) {
          drained.add(dg!);
        }
        return drained.length == 3 ? drained : null;
      });
    });

    test('receive handles a frame split across multiple chunks', () async {
      final full = _frame('100.64.0.10', 5555, _bytes('datagram-split-test'));
      final first = Uint8List.fromList(full.sublist(0, 3));
      final rest = Uint8List.fromList(full.sublist(3));

      goSide.add(first);
      await goSide.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sock.receive(), isNull, reason: 'partial frame should not yield');

      goSide.add(rest);
      await goSide.flush();

      await _pumpUntil(sock, () {
        final dg = sock.receive();
        return dg == null ? null : [dg];
      });
    });

    test('send writes a correctly framed outbound datagram', () async {
      final captured = <int>[];
      final captureComplete = Completer<void>();
      late StreamSubscription<Uint8List> sub;
      sub = goSide.listen(
        (chunk) {
          captured.addAll(chunk);
          if (captured.length >= 17) {
            captureComplete.complete();
            sub.cancel();
          }
        },
      );

      // Use 12 byte payload → total frame = 1+4+2+2+12 = 21 bytes.
      final payload = Uint8List.fromList(List.generate(12, (i) => i + 1));
      final sent = sock.send(payload, InternetAddress('100.64.0.8'), 4444);
      expect(sent, 12);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await goSide.flush();
      await captureComplete.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(captured[0], 4, reason: 'afam byte for IPv4');
      expect(captured.sublist(1, 5), [100, 64, 0, 8]);
      expect((captured[5] << 8) | captured[6], 4444, reason: 'port BE');
      expect((captured[7] << 8) | captured[8], 12, reason: 'payload len BE');
      expect(captured.sublist(9, 21), payload);
    });

    test('send rejects oversize payload', () {
      expect(
        () => sock.send(
          Uint8List(70000),
          InternetAddress('100.64.0.8'),
          4444,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('send throws SocketException when closed', () {
      sock.close();
      expect(
        () => sock.send(
          Uint8List(4),
          InternetAddress('100.64.0.8'),
          4444,
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('close emits RawSocketEvent.closed and stops accepting reads',
        () async {
      final events = <RawSocketEvent>[];
      sock.listen(events.add);
      sock.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, contains(RawSocketEvent.closed));
    });

    test('multicast methods throw UnsupportedError', () {
      expect(
        () => sock.joinMulticast(InternetAddress('224.0.0.1')),
        throwsUnsupportedError,
      );
      expect(
        () => sock.leaveMulticast(InternetAddress('224.0.0.1')),
        throwsUnsupportedError,
      );
    });
  });
}

List<int> _bytes(String s) => s.codeUnits;

String _str(List<int> bytes) => String.fromCharCodes(bytes);

List<int> _frame(String host, int port, List<int> payload) {
  final ip = InternetAddress(host).rawAddress;
  final buf = Uint8List(1 + ip.length + 4 + payload.length);
  buf[0] = ip.length;
  buf.setRange(1, 1 + ip.length, ip);
  final bd = ByteData.sublistView(buf);
  bd.setUint16(1 + ip.length, port);
  bd.setUint16(1 + ip.length + 2, payload.length);
  buf.setRange(1 + ip.length + 4, buf.length, payload);
  return buf;
}

/// Polls [check] at microtask boundaries until it returns non-null or
/// 2s elapses. Shows test failures with the most recent observation
/// rather than a bare timeout.
Future<T> _pumpUntil<T>(
  Stream<RawSocketEvent> source,
  T? Function() check,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  T? result;
  while (DateTime.now().isBefore(deadline)) {
    result = check();
    if (result != null) return result;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('_pumpUntil: condition never satisfied');
}
