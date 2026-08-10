import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/worker/worker.dart';
import 'package:test/test.dart';

void _exitBeforeWorkerReady(SendPort _) {}

void main() {
  test('native bootstrap budget accounts for worker-side preparation', () {
    expect(
      remainingNativeBudgetMillis(
        const Duration(seconds: 30),
        const Duration(seconds: 7),
      ),
      23000,
    );
    expect(
      remainingNativeBudgetMillis(
        const Duration(milliseconds: 5),
        const Duration(milliseconds: 6),
      ),
      0,
    );
  });

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

  test('runtime pushes accept only the bound current or preparing token', () {
    expect(
      acceptsRuntimePush(token: 7, currentToken: 7, preparingToken: null),
      isTrue,
    );
    expect(
      acceptsRuntimePush(token: 7, currentToken: null, preparingToken: 7),
      isTrue,
    );
    expect(
      acceptsRuntimePush(token: 6, currentToken: 7, preparingToken: null),
      isFalse,
    );
    expect(
      acceptsRuntimePush(token: 8, currentToken: 7, preparingToken: 8),
      isFalse,
    );
    expect(
      acceptsRuntimePush(token: 0, currentToken: null, preparingToken: null),
      isFalse,
    );
  });

  test('worker observes an isolate that exits before becoming ready', () async {
    final exited = Completer<void>();
    final worker = Worker(
      publishState: (_) {},
      publishRuntimeError: (_) {},
      publishNodes: (_) {},
      onRuntimeTerminated: (_, _, _, _, _, _) {},
      onExit: (_, _, _, _) => exited.complete(),
      debugEntrypoint: _exitBeforeWorkerReady,
    );

    await expectLater(
      worker.debugWaitUntilReady(),
      throwsA(
        isA<TailscaleOperationException>().having(
          (error) => error.code,
          'code',
          TailscaleErrorCode.workerTerminated,
        ),
      ),
    );
    await exited.future.timeout(const Duration(seconds: 1));
    expect(worker.isDisposed, isTrue);
  });

  group('publication wire contract', () {
    test('coordinate clear omits handle identity', () {
      final payload =
          jsonDecode(
                encodeServeClearPayload(
                  tailnetPort: 443,
                  path: '/api',
                  funnel: false,
                ),
              )
              as Map<String, dynamic>;

      expect(payload, {'tailnetPort': 443, 'path': '/api', 'funnel': false});
    });

    test('handle close includes exact generation and mapping token', () {
      final payload =
          jsonDecode(
                encodeServeClearPayload(
                  tailnetPort: 8443,
                  path: '/',
                  funnel: true,
                  generation: 12,
                  mappingToken: 34,
                ),
              )
              as Map<String, dynamic>;

      expect(payload, {
        'tailnetPort': 8443,
        'path': '/',
        'funnel': true,
        'generation': 12,
        'mappingToken': 34,
      });
    });

    test('partial or non-positive handle identity is rejected', () {
      expect(
        () => encodeServeClearPayload(
          tailnetPort: 443,
          path: '/',
          funnel: false,
          generation: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeServeClearPayload(
          tailnetPort: 443,
          path: '/',
          funnel: false,
          generation: 0,
          mappingToken: 1,
        ),
        throwsRangeError,
      );
    });

    test('maps stable native R5 publication error codes', () {
      expect(
        parseTailscaleErrorCode('dataPlaneNotReady'),
        TailscaleErrorCode.dataPlaneNotReady,
      );
      expect(
        parseTailscaleErrorCode('publicationBootstrapFailure'),
        TailscaleErrorCode.publicationBootstrapFailure,
      );
      expect(
        parseTailscaleErrorCode('serveConfigConflict'),
        TailscaleErrorCode.serveConfigConflict,
      );
      expect(
        parseTailscaleErrorCode('publicationNotApplied'),
        TailscaleErrorCode.publicationNotApplied,
      );
      expect(
        parseTailscaleErrorCode('publicationCommitIndeterminate'),
        TailscaleErrorCode.publicationCommitIndeterminate,
      );
    });
  });

  group('publication bootstrap failure registry', () {
    const failure = TailscaleOperationException(
      'publication bootstrap',
      'first Up failed',
      code: TailscaleErrorCode.publicationBootstrapFailure,
    );

    test('late terminal failure is not retained after up has settled', () {
      final registry = PublicationBootstrapFailureRegistry();

      expect(registry.recordIfWaiting(7, failure), isNull);
      expect(registry.failureFor(7), isNull);
      expect(registry.retainedFailureCount, 0);
    });

    test('in-flight up receives and then retires its exact failure', () async {
      final registry = PublicationBootstrapFailureRegistry();
      final pending = registry.waitFor(7);

      final waiter = registry.recordIfWaiting(7, failure);
      expect(waiter, isNotNull);
      expect(registry.failureFor(7), same(failure));
      expect(registry.retainedFailureCount, 1);

      waiter!.complete(failure);
      expect(await pending, same(failure));

      registry.retire(7);
      expect(registry.failureFor(7), isNull);
      expect(registry.retainedFailureCount, 0);
    });
  });

  group('publication handle delivery', () {
    test('malformed native success actively fails closed', () {
      var compensations = 0;

      expect(
        () => validateServeForwardResultForTesting(
          {
            'url': 'https://demo.tailnet.ts.net/',
            'port': 443,
            'localAddress': '127.0.0.1',
            'localPort': 3000,
            'path': '/',
            'https': true,
            'funnel': false,
            'generation': 7,
            // Missing mappingToken means Dart cannot construct exact ownership.
          },
          funnel: false,
          tailnetPort: 443,
          path: '/',
          onInvalid: () => compensations++,
        ),
        throwsA(
          isA<TailscaleServeException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.publicationCommitIndeterminate,
          ),
        ),
      );
      expect(compensations, 1);
    });

    test(
      'helper-isolate result loss runs exact-runtime compensation',
      () async {
        var compensations = 0;

        await expectLater(
          guardPublicationResultDeliveryForTesting<void>(
            dispatch: () => Future<void>.error(StateError('result port lost')),
            onResultLoss: () => compensations++,
          ),
          throwsA(isA<StateError>()),
        );
        expect(compensations, 1);
      },
    );

    test(
      'delivered native rejection does not quarantine the runtime',
      () async {
        var compensations = 0;

        await expectLater(
          guardPublicationResultDeliveryForTesting<void>(
            dispatch: () => Future<void>.error(
              const TailscaleServeException(
                'Funnel disabled',
                code: TailscaleErrorCode.featureDisabled,
              ),
            ),
            onResultLoss: () => compensations++,
          ),
          throwsA(
            isA<TailscaleServeException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.featureDisabled,
            ),
          ),
        );
        expect(compensations, 0);
      },
    );
  });
}
