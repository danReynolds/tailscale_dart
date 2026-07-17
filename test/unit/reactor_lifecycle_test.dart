import 'dart:isolate';

import 'package:tailscale/src/fd_transport.dart';
import 'package:test/test.dart';

/// Deterministic tests for the reactor's fd-ownership lifecycle, driven through
/// [ReactorTestHarness] + [FakeReactorBackend] so the race windows that real-fd
/// integration tests cannot trigger on demand become assertable. These lock in
/// the single-owner rule: the reactor owns an fd if and only if registration
/// succeeded, so it must never close an fd it failed to register (which the main
/// isolate still owns) and must close a registered fd exactly once on close.
void main() {
  group('reactor fd ownership', () {
    late RawReceivePort events;
    late ReceivePort reply;

    setUp(() {
      events = RawReceivePort();
      reply = ReceivePort();
    });

    tearDown(() {
      events.close();
      reply.close();
    });

    test(
      'successful registration adds the transport without closing its fd',
      () async {
        final backend = FakeReactorBackend();
        final harness = ReactorTestHarness(backend)
          ..enqueueRegister(
            id: 1,
            fd: 100,
            eventPort: events.sendPort,
            replyPort: reply.sendPort,
          );

        harness.processCommands();

        expect(await reply.first, 'ok');
        expect(harness.registeredCount, 1);
        expect(backend.registered, <int>[100]);
        expect(backend.closedFds, isEmpty);
      },
    );

    test(
      'native registration failure does NOT close the fd (main isolate owns it)',
      () async {
        // Regression for the cross-isolate double-close: on a registration
        // failure the reactor must leave the fd alone — the main isolate still
        // owns it and closes it exactly once. A second close from here could,
        // under fd-number reuse, sever an unrelated live descriptor.
        final backend = FakeReactorBackend()..registerResult = -1;
        final harness = ReactorTestHarness(backend)
          ..enqueueRegister(
            id: 1,
            fd: 100,
            eventPort: events.sendPort,
            replyPort: reply.sendPort,
          );

        final armedIdleExit = harness.processCommands();

        expect(await reply.first, 'native reactor register failed');
        expect(harness.registeredCount, 0);
        expect(
          backend.closedFds,
          isEmpty,
          reason: 'reactor must not close an fd it did not register',
        );
        expect(backend.shutdownFds, isEmpty);
        expect(backend.unregistered, isEmpty);
        // A failed registration must still arm idle-exit: otherwise a shard
        // whose first (and only) registration fails would block in the poller
        // forever, keeping the isolate and the whole process alive.
        expect(
          armedIdleExit,
          isTrue,
          reason: 'failed registration must still let the shard idle-exit',
        );
      },
    );

    test('close command closes the registered fd exactly once', () async {
      final backend = FakeReactorBackend();
      final harness = ReactorTestHarness(backend)
        ..enqueueRegister(
          id: 1,
          fd: 100,
          eventPort: events.sendPort,
          replyPort: reply.sendPort,
        )
        ..enqueueClose(1);

      harness.processCommands();

      expect(harness.registeredCount, 0);
      expect(backend.unregistered, <int>[100]);
      expect(backend.shutdownFds, <int>[100]);
      expect(
        backend.closedFds,
        <int>[100],
        reason: 'a registered fd is shut down and closed exactly once',
      );
    });

    test(
      'a close for an unknown transport is a no-op (no fd is touched)',
      () async {
        final backend = FakeReactorBackend();
        // No registration; closing an unknown id must not close any fd.
        ReactorTestHarness(backend)
          ..enqueueClose(999)
          ..processCommands();

        expect(backend.closedFds, isEmpty);
        expect(backend.unregistered, isEmpty);
      },
    );
  });
}
