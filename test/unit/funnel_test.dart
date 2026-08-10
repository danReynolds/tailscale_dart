/// Coverage for the `funnel` namespace's public publication API.
library;

import 'package:test/test.dart';
import 'package:tailscale/src/api/funnel.dart';
import 'package:tailscale/src/errors.dart';

void main() {
  group('Funnel.forward', () {
    test('delegates as HTTPS Funnel and closes through clear', () async {
      final closed =
          <
            ({
              int tailnetPort,
              String path,
              bool funnel,
              int generation,
              int mappingToken,
            })
          >[];
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
                generation: 5,
                mappingToken: 99,
              );
            },
        clearFn:
            ({required tailnetPort, required path, required funnel}) async {},
        closeFn:
            ({
              required tailnetPort,
              required path,
              required funnel,
              required generation,
              required mappingToken,
            }) async {
              closed.add((
                tailnetPort: tailnetPort,
                path: path,
                funnel: funnel,
                generation: generation,
                mappingToken: mappingToken,
              ));
            },
      );

      final publication = await funnel.forward(
        publicPort: 8443,
        localPort: 3000,
        localAddress: 'localhost',
        path: '/api',
      );

      expect(
        publication.url.toString(),
        'https://demo.tailnet.ts.net:8443/api',
      );
      expect(publication.funnel, isTrue);

      await publication.close();

      expect(closed, [
        (
          tailnetPort: 8443,
          path: '/api',
          funnel: true,
          generation: 5,
          mappingToken: 99,
        ),
      ]);
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
        closeFn:
            ({
              required tailnetPort,
              required path,
              required funnel,
              required generation,
              required mappingToken,
            }) async {
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
      expect(
        () => funnel.forward(localPort: 3000, localAddress: '169.254.169.254'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => funnel.forward(localPort: 3000, path: '/api/../admin'),
        throwsA(isA<ArgumentError>()),
      );
      expect(called, isFalse);
    });

    test('rejects a successful result without exact handle identity', () async {
      final funnel = createFunnel(
        forwardFn:
            ({
              required tailnetPort,
              required localPort,
              required localAddress,
              required path,
              required https,
              required funnel,
            }) async => (
              url: Uri.parse('https://demo.tailnet.ts.net/'),
              port: tailnetPort,
              localAddress: localAddress,
              localPort: localPort,
              path: path,
              https: https,
              funnel: funnel,
              generation: -1,
              mappingToken: -1,
            ),
        clearFn:
            ({required tailnetPort, required path, required funnel}) async {},
        closeFn:
            ({
              required tailnetPort,
              required path,
              required funnel,
              required generation,
              required mappingToken,
            }) async {},
      );

      await expectLater(
        funnel.forward(localPort: 3000),
        throwsA(
          isA<TailscaleFunnelException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.publicationCommitIndeterminate,
          ),
        ),
      );
    });
  });
}
