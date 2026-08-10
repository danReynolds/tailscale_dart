import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/http_fd_client.dart';
import 'package:test/test.dart';

void main() {
  group('native HTTP admission', () {
    const fds = (requestBodyFd: -1, responseBodyFd: 12);

    test(
      'routes through the offload gate before the data plane is ready',
      () async {
        final probedTokens = <int>[];
        var offloadCalls = 0;
        var started = false;

        final result = await admitNativeHttpStartForTesting(
          runtimeToken: 41,
          start: () {
            started = true;
            return fds;
          },
          isDataPlaneReady: (token) {
            probedTokens.add(token);
            return false;
          },
          offload: (operation) async {
            offloadCalls++;
            expect(
              started,
              isFalse,
              reason: 'the native call must not run before gate admission',
            );
            return await operation();
          },
        );

        expect(result, fds);
        expect(probedTokens, [41]);
        expect(offloadCalls, 1);
        expect(started, isTrue);
      },
    );

    test('runs directly on the caller isolate once ready', () async {
      var offloadCalls = 0;
      var startCalls = 0;

      final pending = admitNativeHttpStartForTesting(
        runtimeToken: 42,
        start: () {
          startCalls++;
          return fds;
        },
        isDataPlaneReady: (token) => token == 42,
        offload: (operation) async {
          offloadCalls++;
          return await operation();
        },
      );

      // The direct path admits synchronously: the native call has already run
      // before the future is awaited, so no gate permit or helper isolate was
      // involved.
      expect(startCalls, 1);
      expect(await pending, fds);
      expect(offloadCalls, 0);
    });
  });

  group('native HTTP fd validation', () {
    test('accepts an absent request body with a usable response fd', () {
      expect(
        validateNativeHttpFdsForTesting(requestBodyFd: -1, responseBodyFd: 12),
        (requestBodyFd: -1, responseBodyFd: 12),
      );
    });

    test('closes every identifiable fd when the pair is malformed', () {
      final closed = <int>[];

      expect(
        () => validateNativeHttpFdsForTesting(
          requestBodyFd: 11,
          responseBodyFd: -1,
          closeFd: closed.add,
        ),
        throwsA(isA<TailscaleHttpException>()),
      );
      expect(closed, [11]);
    });

    test('closes a usable fd when its companion has the wrong type', () {
      final closed = <int>[];

      expect(
        () => validateNativeHttpFdsForTesting(
          requestBodyFd: 11,
          responseBodyFd: 'invalid',
          closeFd: closed.add,
        ),
        throwsA(isA<TailscaleHttpException>()),
      );
      expect(closed, [11]);
    });
  });
}
