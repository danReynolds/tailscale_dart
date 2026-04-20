/// Coverage for the `tls` namespace glue — bind/delegate behavior and
/// domain lookup forwarding.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';
import 'package:tailscale/src/api/tls.dart' show createTls;

void main() {
  group('tls.bind', () {
    test('wraps bind failures in TailscaleTlsException', () async {
      final tls = createTls(
        bindFn: (_, __) async => throw const TailscaleTlsException('no certs'),
        unbindFn: (_) async {},
        domainsFn: () async => const [],
      );

      await expectLater(
        tls.bind(443),
        throwsA(
          isA<TailscaleTlsException>().having(
            (e) => e.message,
            'message',
            contains('no certs'),
          ),
        ),
      );
    });

    test('surfaces the tailnet port and calls unbind on close', () async {
      int? unboundPort;
      final tls = createTls(
        bindFn: (_, __) async => 7443,
        unbindFn: (loopbackPort) async => unboundPort = loopbackPort,
        domainsFn: () async => const [],
      );

      final server = await tls.bind(0);
      try {
        expect(server.port, 7443);
        expect(server.address, InternetAddress.loopbackIPv4);
        expect(unboundPort, isNull);
      } finally {
        await server.close();
      }

      expect(unboundPort, isNotNull);
      expect(unboundPort, greaterThan(0));
    });
  });

  group('tls.domains', () {
    test('delegates to the injected lookup', () async {
      final tls = createTls(
        bindFn: (_, __) async => throw UnimplementedError(),
        unbindFn: (_) async {},
        domainsFn: () async => const ['node.tailnet.ts.net'],
      );

      expect(await tls.domains(), ['node.tailnet.ts.net']);
    });
  });
}
