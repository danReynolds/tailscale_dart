library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:keybay/keybay.dart';
import 'package:tailscale/src/keybay_state_custody.dart';
import 'package:tailscale/src/state_custody_coordinator.dart';
import 'package:tailscale/src/worker/worker.dart';
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  group('StateCustodyCoordinator', () {
    test('marks native custody before resolving or reading Keybay', () async {
      final events = <String>[];
      final key = _testKey();
      final backend = _FakeBackend()..values[stateStoreDekEntry] = key;
      final binding = _binding(backend, onCreate: () => events.add('storage'));
      final coordinator = _coordinator(events);

      final session = await coordinator.begin(token: 11, binding: binding);
      events.add('read');
      final read = await session.readDek();
      expect(read, orderedEquals(key));
      expect(events.take(3), <String>['mark-active:11', 'storage', 'read']);

      final transferred = session.transferDek(read!);
      expect(read, everyElement(0));
      expect(transferred.materialize().asUint8List(), orderedEquals(key));

      await coordinator.settleAbandonment(
        token: 11,
        disposition: StateCustodyDisposition.none,
      );
      expect(events.last, 'finish:11:true');
      expect(coordinator.ownsToken(11), isFalse);
    });

    test('rejects and wipes a non-32-byte Keybay value', () async {
      final backend = _FakeBackend()
        ..values[stateStoreDekEntry] = Uint8List(31);
      final coordinator = _coordinator(<String>[]);
      final session = await coordinator.begin(
        token: 12,
        binding: _binding(backend),
      );

      await expectLater(
        session.readDek(),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.invalidStateKey,
          ),
        ),
      );
      expect(backend.lastReadBuffer, everyElement(0));
      await coordinator.settleAbandonment(
        token: 12,
        disposition: StateCustodyDisposition.none,
      );
    });

    test('explicit native mark failure releases the caller session', () async {
      final coordinator = StateCustodyCoordinator(
        markActive: (_) async => throw StateError('mark failed'),
        markWriteAttempted: (_) async {},
        finish: (_, {required cleanupSucceeded}) async {},
      );

      await expectLater(
        coordinator.begin(token: 121, binding: _binding(_FakeBackend())),
        throwsStateError,
      );
      expect(coordinator.ownsToken(121), isFalse);
    });

    test(
      'successful completion wipes and releases the caller session',
      () async {
        final events = <String>[];
        final backend = _FakeBackend()..values[stateStoreDekEntry] = _testKey();
        final coordinator = _coordinator(events);
        final session = await coordinator.begin(
          token: 123,
          binding: _binding(backend),
        );
        final key = (await session.readDek())!;

        await coordinator.complete(123);

        expect(key, everyElement(0));
        expect(coordinator.ownsToken(123), isFalse);
        expect(events, <String>['mark-active:123', 'complete:123']);
      },
    );

    test('failed completion retains custody for abandonment', () async {
      final events = <String>[];
      final backend = _FakeBackend()..values[stateStoreDekEntry] = _testKey();
      final coordinator = StateCustodyCoordinator(
        markActive: (token) async => events.add('mark-active:$token'),
        markWriteAttempted: (_) async {},
        complete: (token) async {
          events.add('complete:$token');
          throw StateError('native completion failed');
        },
        finish: (token, {required cleanupSucceeded}) async =>
            events.add('finish:$token:$cleanupSucceeded'),
      );
      final session = await coordinator.begin(
        token: 124,
        binding: _binding(backend),
      );
      final key = (await session.readDek())!;

      await expectLater(coordinator.complete(124), throwsStateError);
      expect(coordinator.ownsToken(124), isTrue);
      expect(key, isNot(everyElement(0)));

      await coordinator.settleAbandonment(
        token: 124,
        disposition: StateCustodyDisposition.none,
      );
      expect(key, everyElement(0));
      expect(coordinator.ownsToken(124), isFalse);
      expect(events, <String>[
        'mark-active:124',
        'complete:124',
        'finish:124:true',
      ]);
    });

    test(
      'abandonment can settle before a raced completion error arrives',
      () async {
        final events = <String>[];
        final completionStarted = Completer<void>();
        final releaseCompletion = Completer<void>();
        final backend = _FakeBackend()..values[stateStoreDekEntry] = _testKey();
        final coordinator = StateCustodyCoordinator(
          markActive: (token) async => events.add('mark-active:$token'),
          markWriteAttempted: (_) async {},
          complete: (token) async {
            events.add('complete:$token');
            completionStarted.complete();
            await releaseCompletion.future;
            throw TailscaleOperationException(
              'state custody',
              'Native abandonment won the custody race.',
              code: TailscaleErrorCode.startupAbandoned,
            );
          },
          finish: (token, {required cleanupSucceeded}) async =>
              events.add('finish:$token:$cleanupSucceeded'),
        );
        final session = await coordinator.begin(
          token: 125,
          binding: _binding(backend),
        );
        final key = (await session.readDek())!;

        final completion = coordinator.complete(125);
        final completionExpectation = expectLater(
          completion,
          throwsA(
            isA<TailscaleOperationException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.startupAbandoned,
            ),
          ),
        );
        await completionStarted.future;

        await coordinator.settleAbandonment(
          token: 125,
          disposition: StateCustodyDisposition.none,
        );
        expect(key, everyElement(0));
        expect(coordinator.ownsToken(125), isFalse);

        releaseCompletion.complete();
        await completionExpectation;
        expect(events, <String>[
          'mark-active:125',
          'complete:125',
          'finish:125:true',
        ]);
      },
    );

    test('terminal discard handles a lost completion response', () async {
      final events = <String>[];
      final backend = _FakeBackend()..values[stateStoreDekEntry] = _testKey();
      final coordinator = StateCustodyCoordinator(
        markActive: (token) async => events.add('mark-active:$token'),
        markWriteAttempted: (_) async {},
        complete: (token) async {
          events.add('complete:$token');
          throw StateError('native response lost after completion');
        },
        finish: (token, {required cleanupSucceeded}) async =>
            events.add('finish:$token:$cleanupSucceeded'),
      );
      final session = await coordinator.begin(
        token: 126,
        binding: _binding(backend),
      );
      final key = (await session.readDek())!;

      await expectLater(coordinator.complete(126), throwsStateError);
      expect(coordinator.ownsToken(126), isTrue);

      // The caller invokes this only after quarantine reports custodyHeld=false,
      // proving native completion committed despite the lost response.
      await coordinator.discardTerminalSession(126);
      await coordinator.discardTerminalSession(126);
      expect(key, everyElement(0));
      expect(coordinator.ownsToken(126), isFalse);
      expect(events, <String>['mark-active:126', 'complete:126']);
    });

    test('fresh write requires a confirmed absent read', () async {
      final coordinator = _coordinator(<String>[]);
      final session = await coordinator.begin(
        token: 1211,
        binding: _binding(_FakeBackend()),
      );
      final rejected = _testKey();
      final expected = Uint8List.fromList(rejected);

      await expectLater(
        session.writeFreshDek(rejected),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.preconditionFailed,
          ),
        ),
      );
      expect(rejected, orderedEquals(expected));
      await coordinator.settleAbandonment(
        token: 1211,
        disposition: StateCustodyDisposition.none,
      );
    });

    test('abandonment joins activation before releasing custody', () async {
      final events = <String>[];
      final marked = Completer<void>();
      var storageCreated = false;
      final coordinator = StateCustodyCoordinator(
        markActive: (_) => marked.future,
        markWriteAttempted: (_) async {},
        finish: (token, {required cleanupSucceeded}) async =>
            events.add('finish:$token:$cleanupSucceeded'),
      );
      final begin = coordinator.begin(
        token: 122,
        binding: _binding(
          _FakeBackend(),
          onCreate: () => storageCreated = true,
        ),
      );
      final beginExpectation = expectLater(
        begin,
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupAbandoned,
          ),
        ),
      );
      final settle = coordinator.settleAbandonment(
        token: 122,
        disposition: StateCustodyDisposition.none,
      );

      marked.complete();
      await beginExpectation;
      await settle;
      expect(storageCreated, isFalse);
      expect(events, <String>['finish:122:true']);
      expect(coordinator.ownsToken(122), isFalse);
    });

    test(
      'possibly committed write error gets exact-entry compensation',
      () async {
        final events = <String>[];
        final backend = _FakeBackend(
          events: events,
          writeCommitsThenThrows: true,
        );
        final coordinator = _coordinator(events);
        final session = await coordinator.begin(
          token: 13,
          binding: _binding(backend),
        );
        expect(await session.readDek(), isNull);

        final key = _testKey();
        await expectLater(
          session.writeFreshDek(key),
          throwsA(
            isA<TailscaleOperationException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.secureStorageUnavailable,
            ),
          ),
        );
        expect(key, everyElement(0));
        expect(backend.values, contains(stateStoreDekEntry));
        await coordinator.settleAbandonment(
          token: 13,
          disposition: StateCustodyDisposition.compensateKey,
        );

        expect(backend.values, isNot(contains(stateStoreDekEntry)));
        expect(backend.deletedKeys, <String>[stateStoreDekEntry]);
        expect(events, <String>[
          'mark-active:13',
          'mark-write:13',
          'write:$stateStoreDekEntry',
          'delete:$stateStoreDekEntry',
          'finish:13:true',
        ]);
      },
    );

    test('preserve disposition never deletes the DEK', () async {
      final events = <String>[];
      final backend = _FakeBackend();
      final coordinator = _coordinator(events);
      final session = await coordinator.begin(
        token: 14,
        binding: _binding(backend),
      );
      expect(await session.readDek(), isNull);
      await session.writeFreshDek(_testKey());

      await coordinator.settleAbandonment(
        token: 14,
        disposition: StateCustodyDisposition.preserveCoherentPair,
      );
      expect(backend.values, contains(stateStoreDekEntry));
      expect(backend.deletedKeys, isEmpty);
      expect(events.last, 'finish:14:true');
    });

    test(
      'fresh write is one-shot and transfer requires its exact buffer',
      () async {
        final backend = _FakeBackend();
        final coordinator = _coordinator(<String>[]);
        final session = await coordinator.begin(
          token: 140,
          binding: _binding(backend),
        );
        expect(await session.readDek(), isNull);
        final source = _testKey();
        final expected = Uint8List.fromList(source);
        final first = await session.writeFreshDek(source);
        expect(source, everyElement(0));

        await expectLater(
          session.writeFreshDek(first),
          throwsA(
            isA<TailscaleOperationException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.preconditionFailed,
            ),
          ),
        );
        expect(first, orderedEquals(expected));

        final repeated = _testKey();
        await expectLater(
          session.writeFreshDek(repeated),
          throwsA(
            isA<TailscaleOperationException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.preconditionFailed,
            ),
          ),
        );
        expect(repeated, orderedEquals(expected));

        final unowned = Uint8List.fromList(expected);
        expect(
          () => session.transferDek(unowned),
          throwsA(
            isA<TailscaleOperationException>().having(
              (error) => error.code,
              'code',
              TailscaleErrorCode.preconditionFailed,
            ),
          ),
        );
        expect(unowned, orderedEquals(expected));

        final transferred = session.transferDek(first);
        expect(
          transferred.materialize().asUint8List(),
          orderedEquals(expected),
        );
        expect(first, everyElement(0));
        await coordinator.settleAbandonment(
          token: 140,
          disposition: StateCustodyDisposition.none,
        );
      },
    );

    test('transfer cannot wipe a DEK while its write is in flight', () async {
      final markWrite = Completer<void>();
      final markStarted = Completer<void>();
      final coordinator = StateCustodyCoordinator(
        markActive: (_) async {},
        markWriteAttempted: (_) {
          markStarted.complete();
          return markWrite.future;
        },
        finish: (_, {required cleanupSucceeded}) async {},
      );
      final session = await coordinator.begin(
        token: 1401,
        binding: _binding(_FakeBackend()),
      );
      expect(await session.readDek(), isNull);
      final source = _testKey();
      final expected = Uint8List.fromList(source);
      final write = session.writeFreshDek(source);
      await markStarted.future;

      expect(
        () => session.transferDek(source),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.lifecycleBusy,
          ),
        ),
      );
      expect(source, everyElement(0));

      markWrite.complete();
      final key = await write;
      expect(key, orderedEquals(expected));
      final transferred = session.transferDek(key);
      expect(transferred.materialize().asUint8List(), orderedEquals(expected));
      await coordinator.settleAbandonment(
        token: 1401,
        disposition: StateCustodyDisposition.none,
      );
    });

    test('duplicate rescue paths share one custody settlement', () async {
      final events = <String>[];
      final backend = _FakeBackend();
      final coordinator = _coordinator(events);
      final session = await coordinator.begin(
        token: 141,
        binding: _binding(backend),
      );
      expect(await session.readDek(), isNull);
      await session.writeFreshDek(_testKey());

      final first = coordinator.settleAbandonment(
        token: 141,
        disposition: StateCustodyDisposition.compensateKey,
      );
      final duplicate = coordinator.settleAbandonment(
        token: 141,
        disposition: StateCustodyDisposition.compensateKey,
      );
      await Future.wait(<Future<void>>[first, duplicate]);
      await coordinator.settleAbandonment(
        token: 141,
        disposition: StateCustodyDisposition.compensateKey,
      );

      expect(backend.deletedKeys, <String>[stateStoreDekEntry]);
      expect(events.where((event) => event == 'finish:141:true'), hasLength(1));
    });

    test('completed settlement receipts stay bounded under stress', () async {
      const firstToken = 2000;
      const settlementCount = 1024;
      var finishCalls = 0;
      final coordinator = StateCustodyCoordinator(
        markActive: (_) async {},
        markWriteAttempted: (_) async {},
        complete: (_) async {},
        finish: (_, {required cleanupSucceeded}) async => finishCalls++,
      );
      final binding = _binding(_FakeBackend());

      for (var offset = 0; offset < settlementCount; offset++) {
        final token = firstToken + offset;
        await coordinator.begin(token: token, binding: binding);
        await coordinator.settleAbandonment(
          token: token,
          disposition: StateCustodyDisposition.none,
        );
      }

      expect(coordinator.retainedSettlementReceiptCount, 256);
      expect(finishCalls, settlementCount);

      await coordinator.settleAbandonment(
        token: firstToken + settlementCount - 1,
        disposition: StateCustodyDisposition.none,
      );
      expect(finishCalls, settlementCount);

      await expectLater(
        coordinator.settleAbandonment(
          token: firstToken,
          disposition: StateCustodyDisposition.none,
        ),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.runtimeCleanupFailed,
          ),
        ),
      );
      expect(finishCalls, settlementCount + 1);
      expect(coordinator.retainedSettlementReceiptCount, 256);
    });

    test('late read is joined and wiped before admission releases', () async {
      final events = <String>[];
      final readCompleter = Completer<Uint8List?>();
      final backend = _FakeBackend(readCompleter: readCompleter);
      final coordinator = _coordinator(events);
      final session = await coordinator.begin(
        token: 15,
        binding: _binding(backend),
      );
      final read = session.readDek();
      final settle = coordinator.settleAbandonment(
        token: 15,
        disposition: StateCustodyDisposition.none,
      );
      var settled = false;
      unawaited(settle.then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      final late = _testKey();
      readCompleter.complete(late);
      await expectLater(
        read,
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupAbandoned,
          ),
        ),
      );
      await settle;
      expect(late, everyElement(0));
      expect(events.last, 'finish:15:true');
    });

    test('late absent read is discarded after abandonment', () async {
      final events = <String>[];
      final readCompleter = Completer<Uint8List?>();
      final coordinator = _coordinator(events);
      final session = await coordinator.begin(
        token: 1501,
        binding: _binding(_FakeBackend(readCompleter: readCompleter)),
      );
      final read = session.readDek();
      final settle = coordinator.settleAbandonment(
        token: 1501,
        disposition: StateCustodyDisposition.none,
      );

      readCompleter.complete(null);
      await expectLater(
        read,
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupAbandoned,
          ),
        ),
      );
      await settle;
      expect(events.last, 'finish:1501:true');
    });

    test('a retained DEK cannot be transferred after abandonment', () async {
      final backend = _FakeBackend()..values[stateStoreDekEntry] = _testKey();
      final coordinator = _coordinator(<String>[]);
      final session = await coordinator.begin(
        token: 151,
        binding: _binding(backend),
      );
      final key = (await session.readDek())!;

      await coordinator.settleAbandonment(
        token: 151,
        disposition: StateCustodyDisposition.none,
      );
      expect(key, everyElement(0));
      expect(
        () => session.transferDek(key),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.startupAbandoned,
          ),
        ),
      );
    });

    test('missing caller session poisons native custody', () async {
      final events = <String>[];
      final coordinator = _coordinator(events);
      await expectLater(
        coordinator.settleAbandonment(
          token: 16,
          disposition: StateCustodyDisposition.compensateKey,
        ),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.runtimeCleanupFailed,
          ),
        ),
      );
      expect(events, <String>['finish:16:false']);
    });
  });

  group('binary DEK bridge', () {
    test('preserves arbitrary bytes and wipes Dart/native buffers', () {
      final key = _testKey();
      final transferred = TransferableTypedData.fromList(<Uint8List>[
        Uint8List.fromList(key),
      ]);
      var supplied = false;
      var wiped = false;

      supplyTransferredDekToNative(
        token: 21,
        transferred: transferred,
        supply: (token, pointer, length) {
          supplied = true;
          expect(token, 21);
          expect(length, stateStoreDekLength);
          expect(pointer.asTypedList(length), orderedEquals(key));
          return '{"ok":true}'.toNativeUtf8();
        },
        freeResponse: (pointer) => calloc.free(pointer),
        afterWipe: (transferredBytes, nativeBytes) {
          wiped = true;
          expect(transferredBytes, everyElement(0));
          expect(nativeBytes, everyElement(0));
        },
      );

      expect(supplied, isTrue);
      expect(wiped, isTrue);
    });

    test('rejects invalid transfer length before native call', () {
      var supplied = false;
      expect(
        () => supplyTransferredDekToNative(
          token: 22,
          transferred: TransferableTypedData.fromList(<Uint8List>[
            Uint8List(31),
          ]),
          supply: (token, pointer, length) {
            supplied = true;
            return ffi.nullptr;
          },
          freeResponse: (_) {},
        ),
        throwsA(
          isA<TailscaleOperationException>().having(
            (error) => error.code,
            'code',
            TailscaleErrorCode.invalidStateKey,
          ),
        ),
      );
      expect(supplied, isFalse);
    });

    test('secure generator returns independent 32-byte binary keys', () {
      final first = generateStateStoreDek();
      final second = generateStateStoreDek();
      expect(first, hasLength(stateStoreDekLength));
      expect(second, hasLength(stateStoreDekLength));
      expect(first, isNot(orderedEquals(second)));
    });
  });
}

StateCustodyCoordinator _coordinator(List<String> events) =>
    StateCustodyCoordinator(
      markActive: (token) async => events.add('mark-active:$token'),
      markWriteAttempted: (token) async => events.add('mark-write:$token'),
      complete: (token) async => events.add('complete:$token'),
      finish: (token, {required cleanupSucceeded}) async =>
          events.add('finish:$token:$cleanupSucceeded'),
    );

KeybayStateCustodyBinding _binding(
  _FakeBackend backend, {
  void Function()? onCreate,
}) => KeybayStateCustodyBinding(
  hostAppId: 'com.example.test',
  storageFactory: ({required appId}) {
    onCreate?.call();
    return SecretStorage.withBackend(backend);
  },
);

Uint8List _testKey() {
  final key = Uint8List.fromList(
    List<int>.generate(stateStoreDekLength, (index) => index * 7 & 0xff),
  );
  key[0] = 0;
  key[key.length - 1] = 0xff;
  return key;
}

final class _FakeBackend implements SecretBackend {
  _FakeBackend({
    this.events,
    this.writeCommitsThenThrows = false,
    this.readCompleter,
  });

  final List<String>? events;
  final bool writeCommitsThenThrows;
  final Completer<Uint8List?>? readCompleter;
  final Map<String, Uint8List> values = <String, Uint8List>{};
  final List<String> deletedKeys = <String>[];
  Uint8List? lastReadBuffer;

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: true);

  @override
  Future<bool> contains(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    events?.add('delete:$key');
    deletedKeys.add(key);
    values.remove(key);
  }

  @override
  Future<BackendInfo> describe() async => BackendInfo(
    scheme: StorageScheme.nativeItems,
    available: true,
    locked: false,
    capabilities: capabilities,
  );

  @override
  Future<Uint8List?> read(String key) async {
    if (readCompleter != null) {
      final value = await readCompleter!.future;
      lastReadBuffer = value;
      return value;
    }
    final value = values[key];
    lastReadBuffer = value == null ? null : Uint8List.fromList(value);
    return lastReadBuffer;
  }

  @override
  Future<Map<String, Uint8List>> readAll() async => <String, Uint8List>{
    for (final entry in values.entries)
      entry.key: Uint8List.fromList(entry.value),
  };

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async {
    events?.add('write:$key');
    values[key] = Uint8List.fromList(value);
    if (writeCommitsThenThrows) {
      throw StateError('write response lost after commit');
    }
  }
}
