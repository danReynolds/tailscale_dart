/// Coverage for the `funnel` namespace's public publication API.
library;

import 'package:test/test.dart';
import 'package:tailscale/src/api/funnel.dart';

void main() {
  group('Funnel.forward', () {
    test('delegates as HTTPS Funnel and closes through clear', () async {
      final cleared = <({int tailnetPort, String path, bool funnel})>[];
      final funnel = createFunnel(
        forwardFn:
            ({
              required tailnetPort,
              required localPort,
              required localAddress,
              required path,
              required https,
              required funnel,
            }) async {
              expect(tailnetPort, 8443);
              expect(localPort, 3000);
              expect(localAddress, '127.0.0.1');
              expect(path, '/api');
              expect(https, isTrue);
              expect(funnel, isTrue);
              return (
                url: Uri.parse('https://demo.tailnet.ts.net:8443/api'),
                port: tailnetPort,
                localAddress: localAddress,
                localPort: localPort,
                path: path,
                https: https,
                funnel: funnel,
              );
            },
        clearFn:
            ({required tailnetPort, required path, required funnel}) async {
              cleared.add((
                tailnetPort: tailnetPort,
                path: path,
                funnel: funnel,
              ));
            },
      );

      final publication = await funnel.forward(
        publicPort: 8443,
        localPort: 3000,
        path: '/api',
      );

      expect(
        publication.url.toString(),
        'https://demo.tailnet.ts.net:8443/api',
      );
      expect(publication.funnel, isTrue);

      await publication.close();

      expect(cleared, [(tailnetPort: 8443, path: '/api', funnel: true)]);
    });

    test('rejects invalid options before calling native code', () async {
      var called = false;
      final funnel = createFunnel(
        forwardFn:
            ({
              required tailnetPort,
              required localPort,
              required localAddress,
              required path,
              required https,
              required funnel,
            }) async {
              called = true;
              throw StateError('unreachable');
            },
        clearFn:
            ({required tailnetPort, required path, required funnel}) async {
              called = true;
            },
      );

      expect(
        () => funnel.forward(publicPort: 0, localPort: 3000),
        throwsA(isA<RangeError>()),
      );
      expect(
        () => funnel.forward(localPort: 3000, localAddress: ' '),
        throwsA(isA<ArgumentError>()),
      );
      expect(called, isFalse);
    });
  });
}
