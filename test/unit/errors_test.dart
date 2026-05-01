/// Coverage for the library-level error taxonomy — [TailscaleErrorCode],
/// the per-operation exception classes, and [TailscaleRuntimeError]
/// (async errors pushed from Go).
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('TailscaleErrorCode', () {
    test('operation exceptions carry code and statusCode', () {
      const err = TailscaleServeException(
        'config moved on',
        code: TailscaleErrorCode.conflict,
        statusCode: 412,
      );
      expect(err.operation, 'serve');
      expect(err.code, TailscaleErrorCode.conflict);
      expect(err.statusCode, 412);
      expect(err.toString(), contains('conflict'));
      expect(err.toString(), contains('config moved on'));
    });

    test('default code is unknown and omitted from toString', () {
      const err = TailscaleUpException('boom');
      expect(err.code, TailscaleErrorCode.unknown);
      expect(err.toString(), isNot(contains('unknown')));
    });

    test('every namespace has its own exception subtype', () {
      const errors = <TailscaleOperationException>[
        TailscaleUpException('_'),
        TailscaleHttpException('_'),
        TailscaleStatusException('_'),
        TailscaleLogoutException('_'),
        TailscaleTcpException('_'),
        TailscaleUdpException('_'),
        TailscaleTlsException('_'),
        TailscaleTaildropException('_'),
        TailscaleServeException('_'),
        TailscalePrefsException('_'),
        TailscaleProfilesException('_'),
        TailscaleExitNodeException('_'),
        TailscaleDiagException('_'),
      ];
      final types = errors.map((e) => e.runtimeType).toSet();
      expect(types.length, errors.length);
    });
  });

  group('TailscaleRuntimeError', () {
    test('parses known runtime error codes', () {
      final error = TailscaleRuntimeError.fromPushPayload({
        'error': 'watch failed',
        'code': 'watcher',
      });
      expect(error.message, 'watch failed');
      expect(error.code, TailscaleRuntimeErrorCode.watcher);
    });

    test('unknown runtime error codes fall back to unknown', () {
      final error = TailscaleRuntimeError.fromPushPayload({
        'error': 'mystery',
        'code': 'something-new',
      });
      expect(error.code, TailscaleRuntimeErrorCode.unknown);
    });

    test('equal runtime errors compare equal', () {
      final a = TailscaleRuntimeError.fromPushPayload({
        'error': 'x',
        'code': 'node',
      });
      final b = TailscaleRuntimeError.fromPushPayload({
        'error': 'x',
        'code': 'node',
      });
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
