library;

import 'package:tailscale/src/worker/worker.dart'
    show debugMaxSemaphoreConcurrency;
import 'package:test/test.dart';

void main() {
  group('offload concurrency gate', () {
    test('caps concurrency at the permit count under overload', () async {
      // 20 tasks, 4 permits: never more than 4 run at once, and the cap is
      // fully used (peak == permits). This is the F1 regression guard — without
      // the semaphore, offloaded native calls spawn unbounded helper isolates.
      final peak = await debugMaxSemaphoreConcurrency(permits: 4, tasks: 20);
      expect(peak, 4);
    });

    test('does not throttle when permits exceed demand', () async {
      final peak = await debugMaxSemaphoreConcurrency(permits: 8, tasks: 5);
      expect(peak, 5);
    });

    test('serializes fully with a single permit', () async {
      final peak = await debugMaxSemaphoreConcurrency(permits: 1, tasks: 10);
      expect(peak, 1);
    });
  });
}
