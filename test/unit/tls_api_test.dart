import 'package:tailscale/src/api/connection.dart';
import 'package:tailscale/src/api/tls.dart';
import 'package:test/test.dart';

void main() {
  group('Tls API', () {
    test('domains delegates to the native domain source', () async {
      final tls = createTls(
        listenFn: (_, _) => throw StateError('not called'),
        closeListenerFn: (_) => throw StateError('not called'),
        domainsFn: () async => const ['demo.tailnet.ts.net'],
      );

      expect(await tls.domains(), ['demo.tailnet.ts.net']);
    });

    test(
      'bind returns a package-native listener and closes native listener',
      () async {
        final closed = <int>[];
        final tls = createTls(
          listenFn: (port, address) async {
            expect(port, 443);
            expect(address, '100.64.0.1');
            return (
              listenerId: 42,
              local: const TailscaleEndpoint(address: '100.64.0.1', port: 443),
            );
          },
          closeListenerFn: (listenerId) async {
            closed.add(listenerId);
          },
          domainsFn: () async => const [],
        );

        final listener = await tls.bind(port: 443, address: '100.64.0.1');
        expect(
          listener.local,
          const TailscaleEndpoint(address: '100.64.0.1', port: 443),
        );
        expect(listener.connections, isA<Stream<TailscaleConnection>>());

        await listener.close();
        expect(closed, [42]);
      },
    );
  });
}
