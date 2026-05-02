/// Coverage for the `serve` namespace's package-native publication API.
library;

import 'package:test/test.dart';
import 'package:tailscale/src/api/serve.dart';

void main() {
  group('Serve.forward', () {
    test(
      'delegates normalized options and returns a closable publication',
      () async {
        final cleared = <({int tailnetPort, String path, bool funnel})>[];
        final serve = createServe(
          forwardFn:
              ({
                required tailnetPort,
                required localPort,
                required localAddress,
                required path,
                required https,
                required funnel,
              }) async {
                expect(tailnetPort, 443);
                expect(localPort, 3000);
                expect(localAddress, '127.0.0.1');
                expect(path, '/');
                expect(https, isTrue);
                expect(funnel, isFalse);
                return (
                  url: Uri.parse('https://demo.tailnet.ts.net/'),
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

        final publication = await serve.forward(
          tailnetPort: 443,
          localPort: 3000,
          path: '',
        );

        expect(publication.url.toString(), 'https://demo.tailnet.ts.net/');
        expect(publication.port, 443);
        expect(publication.localPort, 3000);
        expect(publication.funnel, isFalse);
        expect(publication.toString(), contains('port: 443'));

        await publication.close();
        await publication.close();

        expect(cleared, [(tailnetPort: 443, path: '/', funnel: false)]);
      },
    );

    test(
      'rejects invalid ports and paths before calling native code',
      () async {
        var called = false;
        final serve = createServe(
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
          () => serve.forward(tailnetPort: 0, localPort: 3000),
          throwsA(isA<RangeError>()),
        );
        expect(
          () => serve.forward(tailnetPort: 443, localPort: 3000, path: 'api'),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => serve.forward(
            tailnetPort: 443,
            localPort: 3000,
            localAddress: '169.254.169.254',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => serve.forward(
            tailnetPort: 443,
            localPort: 3000,
            path: '/api/../admin',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(called, isFalse);
      },
    );
  });
}
