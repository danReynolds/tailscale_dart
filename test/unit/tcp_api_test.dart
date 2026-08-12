import 'package:tailscale/src/api/connection.dart';
import 'package:tailscale/src/api/tcp.dart';
import 'package:tailscale/src/errors.dart';
import 'package:test/test.dart';

void main() {
  test('Tcp.dial wraps asynchronous fd adoption failures', () async {
    final tcp = createTcp(
      dialFn: (_, _, _) async => (
        fd: -1,
        local: const TailscaleEndpoint(address: '100.64.0.1', port: 1234),
        remote: const TailscaleEndpoint(address: '100.64.0.2', port: 80),
      ),
      listenFn: (_, _) => throw StateError('not called'),
      closeListenerFn: (_) => throw StateError('not called'),
    );

    await expectLater(
      tcp.dial('100.64.0.2', 80),
      throwsA(
        isA<TailscaleTcpException>()
            .having(
              (error) => error.message,
              'message',
              'tcp.dial failed for 100.64.0.2:80',
            )
            .having((error) => error.cause, 'cause', isNotNull),
      ),
    );
  });
}
