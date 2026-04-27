import 'dart:async';

import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  test('public runtime methods require Tailscale.init', () async {
    final tailscale = Tailscale.instance;

    await _expectUsageError(() => tailscale.up(authKey: 'test-auth-key'));
    await _expectUsageError(tailscale.status);
    await _expectUsageError(tailscale.nodes);
    await _expectUsageError(() => tailscale.nodeByIp('100.64.0.1'));
    await _expectUsageError(() => tailscale.whois('100.64.0.1'));
    await _expectUsageError(tailscale.down);
    await _expectUsageError(tailscale.logout);
  });
}

Future<void> _expectUsageError(FutureOr<Object?> Function() call) async {
  Object? caught;
  try {
    await call();
  } catch (error) {
    caught = error;
  }
  expect(caught, isA<TailscaleUsageException>());
}
