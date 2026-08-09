import 'dart:async';

import 'package:tailscale/src/worker/worker.dart';
import 'package:test/test.dart';

void main() {
  test(
    'lifecycle intent is reserved before asynchronous preparation',
    () async {
      final queue = WorkerLifecycleQueue();
      final releasePreparation = Completer<void>();
      final preparationStarted = Completer<void>();
      final events = <String>[];

      final start = queue.run(() async {
        events.add('start preparing');
        preparationStarted.complete();
        await releasePreparation.future;
        events.add('start committed');
      });
      await preparationStarted.future;

      final down = queue.run(() async {
        events.add('down');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, ['start preparing']);

      releasePreparation.complete();
      await Future.wait([start, down]);
      expect(events, ['start preparing', 'start committed', 'down']);
    },
  );

  test('a failed lifecycle call does not strand the queue', () async {
    final queue = WorkerLifecycleQueue();

    await expectLater(
      queue.run<void>(() async => throw StateError('start failed')),
      throwsStateError,
    );
    await expectLater(queue.run(() async => 'down'), completion('down'));
  });
}
