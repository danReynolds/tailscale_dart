/// Coverage for the `serve` namespace's package-native publication API.
library;

import 'package:test/test.dart';
import 'package:tailscale/src/api/serve.dart';
import 'package:tailscale/src/errors.dart';

void main() {
  group('Serve.forward', () {
    test(
      'delegates normalized options and returns a closable publication',
      () async {
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
                  generation: 7,
                  mappingToken: 41,
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

        final publication = await serve.forward(
          tailnetPort: 443,
          localPort: 3000,
          localAddress: 'LOCALHOST',
          path: '',
        );

        expect(publication.url.toString(), 'https://demo.tailnet.ts.net/');
        expect(publication.port, 443);
        expect(publication.localPort, 3000);
        expect(publication.funnel, isFalse);
        expect(publication.toString(), contains('port: 443'));

        await publication.close();
        await publication.close();

        expect(closed, [
          (
            tailnetPort: 443,
            path: '/',
            funnel: false,
            generation: 7,
            mappingToken: 41,
          ),
        ]);
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

    test(
      'replaced and old-generation handles close only their exact mapping',
      () async {
        var generation = 10;
        var nextMappingToken = 0;
        final current =
            <
              ({int port, String path, bool funnel}),
              ({int generation, int mappingToken})
            >{};

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
                final mappingToken = ++nextMappingToken;
                current[(port: tailnetPort, path: path, funnel: funnel)] = (
                  generation: generation,
                  mappingToken: mappingToken,
                );
                return (
                  url: Uri.parse('https://demo.tailnet.ts.net$path'),
                  port: tailnetPort,
                  localAddress: localAddress,
                  localPort: localPort,
                  path: path,
                  https: https,
                  funnel: funnel,
                  generation: generation,
                  mappingToken: mappingToken,
                );
              },
          clearFn:
              ({required tailnetPort, required path, required funnel}) async {
                current.remove((port: tailnetPort, path: path, funnel: funnel));
              },
          closeFn:
              ({
                required tailnetPort,
                required path,
                required funnel,
                required generation,
                required mappingToken,
              }) async {
                final key = (port: tailnetPort, path: path, funnel: funnel);
                if (current[key] ==
                    (generation: generation, mappingToken: mappingToken)) {
                  current.remove(key);
                }
              },
        );

        final replaced = await serve.forward(tailnetPort: 443, localPort: 3000);
        final replacement = await serve.forward(
          tailnetPort: 443,
          localPort: 3001,
        );

        await replaced.close();
        expect(current.values.single.mappingToken, 2);

        generation = 11;
        final nextGeneration = await serve.forward(
          tailnetPort: 443,
          localPort: 3002,
        );
        await replacement.close();
        expect(current.values.single, (generation: 11, mappingToken: 3));

        await nextGeneration.close();
        expect(current, isEmpty);
      },
    );

    test('failed close remains retryable and success is idempotent', () async {
      var closeAttempts = 0;
      final serve = createServe(
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
              generation: 12,
              mappingToken: 44,
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
            }) {
              closeAttempts++;
              if (closeAttempts == 1) {
                throw const TailscaleServeException('temporary close failure');
              }
              return Future<void>.value();
            },
      );
      final publication = await serve.forward(
        tailnetPort: 443,
        localPort: 3000,
      );

      await expectLater(
        publication.close(),
        throwsA(isA<TailscaleException>()),
      );
      await publication.close();
      await publication.close();

      expect(closeAttempts, 2);
    });

    test('rejects a successful result without exact handle identity', () async {
      final serve = createServe(
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
              generation: 0,
              mappingToken: 0,
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
        serve.forward(tailnetPort: 443, localPort: 3000),
        throwsA(
          isA<TailscaleServeException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.publicationCommitIndeterminate,
          ),
        ),
      );
    });
  });
}
