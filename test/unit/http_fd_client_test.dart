import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/http_fd_client.dart';
import 'package:test/test.dart';

void main() {
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
