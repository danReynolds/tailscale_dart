import 'dart:async';

import 'package:tailscale/src/worker/worker.dart';
import 'package:test/test.dart';

void main() {
  test(
    'lifecycle intent is reserved before asynchronous preparation',
    () async {
      final queue = LifecycleQueue();
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

  test('teardown waits for the complete public up lifecycle', () async {
    final queue = LifecycleQueue();
    final nativeStartReturned = Completer<void>();
    final releaseStableState = Completer<void>();
    final events = <String>[];

    final up = queue.run(() async {
      events.add('native start');
      nativeStartReturned.complete();
      await releaseStableState.future;
      events.add('stable state');
    });
    await nativeStartReturned.future;

    final down = queue.run(() async {
      events.add('down');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['native start']);

    releaseStableState.complete();
    await Future.wait([up, down]);
    expect(events, ['native start', 'stable state', 'down']);
  });

  test('a failed lifecycle call does not strand the queue', () async {
    final queue = LifecycleQueue();

    await expectLater(
      queue.run<void>(() async => throw StateError('start failed')),
      throwsStateError,
    );
    await expectLater(queue.run(() async => 'down'), completion('down'));
  });
}
