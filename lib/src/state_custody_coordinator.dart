import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:keybay/keybay.dart';
import 'package:meta/meta.dart';

import 'errors.dart';
import 'ffi_bindings.dart' as native;
import 'keybay_state_custody.dart';
import 'worker/worker.dart';

typedef CustodyTokenCall = Future<void> Function(int token);
typedef FinishCustodyCall =
    Future<void> Function(int token, {required bool cleanupSucceeded});
typedef PreparedDekNativeCall =
    ffi.Pointer<Utf8> Function(
      int token,
      ffi.Pointer<ffi.Uint8> key,
      int keyLength,
    );
typedef NativeResponseFree = void Function(ffi.Pointer<Utf8> pointer);

/// Caller-isolate owner for non-cancellable Keybay custody operations.
///
/// Public persistent operations call [begin] only after native keyless format
/// classification has acquired the exact state lease.
@internal
final class StateCustodyCoordinator {
  StateCustodyCoordinator({
    CustodyTokenCall markActive = markNativeCustodyActive,
    CustodyTokenCall markWriteAttempted = markNativeCustodyWriteAttempted,
    CustodyTokenCall complete = completeNativePersistentCustody,
    FinishCustodyCall finish = finishNativeCustody,
  }) : _markActive = markActive,
       _markWriteAttempted = markWriteAttempted,
       _complete = complete,
       _finish = finish;

  final CustodyTokenCall _markActive;
  final CustodyTokenCall _markWriteAttempted;
  final CustodyTokenCall _complete;
  final FinishCustodyCall _finish;
  final Map<int, StateCustodySession> _sessions = <int, StateCustodySession>{};
  final Map<int, Future<void>> _settlementReceipts = <int, Future<void>>{};
  final Queue<int> _completedSettlementOrder = Queue<int>();

  static const int _maximumCompletedSettlementReceipts = 256;

  /// Binds one native preparation token to the package-owned Keybay namespace.
  Future<StateCustodySession> begin({
    required int token,
    required KeybayStateCustodyBinding binding,
  }) async {
    if (token <= 0) {
      throw const TailscaleUsageException(
        'State custody token must be positive.',
      );
    }
    if (_sessions.containsKey(token)) {
      throw TailscaleOperationException(
        'state custody',
        'State custody is already active for token $token.',
        code: TailscaleErrorCode.lifecycleBusy,
      );
    }

    final session = StateCustodySession._(
      token: token,
      binding: binding,
      markWriteAttempted: _markWriteAttempted,
    );
    _sessions[token] = session;
    try {
      await session._activate(_markActive);
      return session;
    } catch (_) {
      // An explicit mark failure means native never entered custody. Once the
      // mark succeeds, even storage resolution failure must stay registered
      // until token-qualified abandonment releases native admission.
      if (!session._nativeCustodyMarked) {
        session._wipeLiveBuffers();
        _sessions.remove(token);
      }
      rethrow;
    }
  }

  /// Releases a successful lifecycle-scoped session only after native has
  /// recorded that no abandonment compensation can still be required.
  Future<void> complete(int token) async {
    final session = _sessions[token];
    if (session == null) {
      throw TailscaleOperationException(
        'state custody',
        'State custody session $token is unavailable.',
        code: TailscaleErrorCode.staleRuntime,
      );
    }
    await session._awaitSettledOperation();
    await _complete(token);
    session._wipeLiveBuffers();
    _sessions.remove(token);
  }

  /// Joins late custody, performs the exact compensation requested by native,
  /// then releases admission. A missing session or failed delete is fail-closed.
  Future<void> settleAbandonment({
    required int token,
    required StateCustodyDisposition disposition,
  }) {
    final existing = _settlementReceipts[token];
    if (existing != null) return existing;
    final settlement = _settleAbandonmentOnce(
      token: token,
      disposition: disposition,
    );
    // Keep the token-qualified receipt: two rescue paths can both obtain a
    // custody-held native receipt before the first one calls FinishCustody.
    // Runtime tokens are never reused, so replaying the same Future is safer
    // than a late duplicate poisoning an already-settled generation.
    _settlementReceipts[token] = settlement;
    settlement.then<void>(
      (_) => _recordCompletedSettlement(token, settlement),
      onError: (Object _, StackTrace _) =>
          _recordCompletedSettlement(token, settlement),
    );
    return settlement;
  }

  void _recordCompletedSettlement(int token, Future<void> settlement) {
    if (!identical(_settlementReceipts[token], settlement)) return;
    _completedSettlementOrder.addLast(token);
    while (_completedSettlementOrder.length >
        _maximumCompletedSettlementReceipts) {
      final expired = _completedSettlementOrder.removeFirst();
      _settlementReceipts.remove(expired);
    }
  }

  Future<void> _settleAbandonmentOnce({
    required int token,
    required StateCustodyDisposition disposition,
  }) async {
    final session = _sessions[token];
    if (session == null) {
      Object? finishError;
      try {
        await _finish(token, cleanupSucceeded: false);
      } catch (error) {
        finishError = error;
      }
      throw TailscaleOperationException(
        'state custody',
        'Native retained custody for token $token, but its caller-isolate '
            'session was unavailable. Restart the process before retrying.',
        code: TailscaleErrorCode.runtimeCleanupFailed,
        cause: finishError,
      );
    }

    Object? cleanupError;
    try {
      await session._settle(disposition);
    } catch (error) {
      cleanupError = error;
    }

    Object? finishError;
    try {
      await _finish(token, cleanupSucceeded: cleanupError == null);
    } catch (error) {
      finishError = error;
    } finally {
      session._wipeLiveBuffers();
      _sessions.remove(token);
    }

    if (cleanupError != null || finishError != null) {
      throw TailscaleOperationException(
        'state custody',
        'State custody cleanup was not confirmed for token $token. Restart '
            'the process before retrying.',
        code: TailscaleErrorCode.runtimeCleanupFailed,
        cause: cleanupError ?? finishError,
      );
    }
  }

  /// Drops caller-side custody after native quarantine proves it is terminal
  /// and no longer retains custody for [token].
  ///
  /// This is the response-loss counterpart to [complete]: native completion
  /// may commit even when its response Future fails on the caller isolate.
  @internal
  Future<void> discardTerminalSession(int token) async {
    final session = _sessions[token];
    if (session == null) return;
    await session._awaitSettledOperation();
    if (!identical(_sessions[token], session)) return;
    session._wipeLiveBuffers();
    _sessions.remove(token);
  }

  @visibleForTesting
  bool ownsToken(int token) => _sessions.containsKey(token);

  @visibleForTesting
  int get retainedSettlementReceiptCount => _settlementReceipts.length;
}

/// One lifecycle-scoped Keybay container and its mutable DEK buffers.
@internal
final class StateCustodySession {
  StateCustodySession._({
    required this.token,
    required this.binding,
    required CustodyTokenCall markWriteAttempted,
  }) : _markWriteAttempted = markWriteAttempted;

  final int token;
  final KeybayStateCustodyBinding binding;
  final CustodyTokenCall _markWriteAttempted;
  final Set<Uint8List> _liveBuffers = HashSet<Uint8List>.identity();

  SecretStorage? _storage;
  Future<void> _custodyTail = Future<void>.value();
  bool _operationInFlight = false;
  bool _abandoning = false;
  bool _nativeCustodyMarked = false;
  bool _readAttempted = false;
  bool _readCompleted = false;
  bool _readWasAbsent = false;
  bool _freshWriteAttempted = false;

  Future<void> _activate(CustodyTokenCall markActive) =>
      _runOperation<void>(() async {
        // Native must retain admission before resolving Keybay: constructing
        // a production SecretStorage can itself probe platform custody policy.
        await markActive(token);
        _nativeCustodyMarked = true;
        if (_abandoning) throw _abandonedError();
        try {
          _storage = binding.createStorage();
        } catch (error, stackTrace) {
          Error.throwWithStackTrace(
            mapKeybayStateCustodyError(
              error,
              action: 'resolve the Tailscale key container',
            ),
            stackTrace,
          );
        }
      });

  SecretStorage get _requiredStorage {
    final storage = _storage;
    if (storage == null) {
      throw TailscaleOperationException(
        'state custody',
        'The Keybay container could not be resolved for token $token.',
        code: TailscaleErrorCode.preconditionFailed,
      );
    }
    return storage;
  }

  /// Reads and validates a DEK without creating or repairing custody.
  Future<Uint8List?> readDek() {
    if (_readAttempted) {
      return Future<Uint8List?>.error(
        TailscaleOperationException(
          'state custody',
          'The DEK was already read for token $token.',
          code: TailscaleErrorCode.preconditionFailed,
        ),
      );
    }
    _readAttempted = true;
    return _runOperation<Uint8List?>(() async {
      late final Uint8List? received;
      try {
        received = await _requiredStorage.read(stateStoreDekEntry);
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          mapKeybayStateCustodyError(
            error,
            action: 'read the Tailscale state key',
          ),
          stackTrace,
        );
      }
      if (received == null) {
        if (_abandoning) throw _abandonedError();
        _readCompleted = true;
        _readWasAbsent = true;
        return null;
      }
      final owned = Uint8List.fromList(received);
      _wipe(received);
      if (owned.length != stateStoreDekLength) {
        _wipe(owned);
        throw TailscaleOperationException(
          'state custody',
          'Keybay returned ${owned.length} DEK bytes; expected '
              '$stateStoreDekLength.',
          code: TailscaleErrorCode.invalidStateKey,
        );
      }
      if (_abandoning) {
        _wipe(owned);
        throw _abandonedError();
      }
      _readCompleted = true;
      _readWasAbsent = false;
      _liveBuffers.add(owned);
      return owned;
    });
  }

  /// Takes ownership of a newly generated DEK and writes it exactly once.
  ///
  /// The caller's buffer is copied and wiped at the accepted handoff. The
  /// returned buffer is the only session-owned value eligible for transfer.
  /// Every write error remains possibly committed until abandonment performs
  /// the exact-entry compensating delete.
  Future<Uint8List> writeFreshDek(Uint8List key) {
    _validateDek(key);
    if (_operationInFlight) {
      return Future<Uint8List>.error(
        TailscaleOperationException(
          'state custody',
          'A Keybay operation is still active for token $token.',
          code: TailscaleErrorCode.lifecycleBusy,
        ),
      );
    }
    if (!_readCompleted || !_readWasAbsent) {
      return Future<Uint8List>.error(
        TailscaleOperationException(
          'state custody',
          'A fresh DEK can be written only after one confirmed absent read '
              'for token $token.',
          code: TailscaleErrorCode.preconditionFailed,
        ),
      );
    }
    if (_freshWriteAttempted) {
      return Future<Uint8List>.error(
        TailscaleOperationException(
          'state custody',
          'A fresh DEK write was already attempted for token $token.',
          code: TailscaleErrorCode.preconditionFailed,
        ),
      );
    }
    final owned = Uint8List.fromList(key);
    _freshWriteAttempted = true;
    _wipe(key);
    _liveBuffers.add(owned);
    return _writeFreshDek(owned);
  }

  Future<Uint8List> _writeFreshDek(Uint8List key) async {
    try {
      await _runOperation<void>(() async {
        await _markWriteAttempted(token);
        final owned = Uint8List.fromList(key);
        try {
          try {
            await _requiredStorage.write(
              stateStoreDekEntry,
              owned,
              label: stateStoreDekLabel,
            );
          } catch (error, stackTrace) {
            Error.throwWithStackTrace(
              mapKeybayStateCustodyError(
                error,
                action: 'write the Tailscale state key',
              ),
              stackTrace,
            );
          }
        } finally {
          _wipe(owned);
        }
      });
      return key;
    } catch (_) {
      _liveBuffers.remove(key);
      _wipe(key);
      rethrow;
    }
  }

  /// Moves a validated read/generated DEK into a one-shot isolate message and
  /// wipes the caller-owned source immediately after the transfer copy exists.
  TransferableTypedData transferDek(Uint8List key) {
    if (_operationInFlight) {
      throw TailscaleOperationException(
        'state custody',
        'A Keybay operation is still active for token $token.',
        code: TailscaleErrorCode.lifecycleBusy,
      );
    }
    if (_abandoning) {
      if (_liveBuffers.remove(key)) _wipe(key);
      throw _abandonedError();
    }
    _validateDek(key);
    if (!_liveBuffers.contains(key)) {
      throw TailscaleOperationException(
        'state custody',
        'The transferred DEK is not owned by custody token $token.',
        code: TailscaleErrorCode.preconditionFailed,
      );
    }
    final transfer = TransferableTypedData.fromList(<Uint8List>[key]);
    _liveBuffers.remove(key);
    _wipe(key);
    return transfer;
  }

  Future<T> _runOperation<T>(Future<T> Function() operation) {
    if (_abandoning) {
      return Future<T>.error(_abandonedError());
    }
    if (_operationInFlight) {
      return Future<T>.error(
        TailscaleOperationException(
          'state custody',
          'Another Keybay operation is active for token $token.',
          code: TailscaleErrorCode.lifecycleBusy,
        ),
      );
    }
    _operationInFlight = true;
    final result = operation();
    _custodyTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result.whenComplete(() => _operationInFlight = false);
  }

  TailscaleOperationException _abandonedError() => TailscaleOperationException(
    'state custody',
    'State custody completed after token $token was abandoned.',
    code: TailscaleErrorCode.startupAbandoned,
  );

  Future<void> _settle(StateCustodyDisposition disposition) async {
    _abandoning = true;
    await _custodyTail;
    _wipeLiveBuffers();
    if (disposition != StateCustodyDisposition.compensateKey) return;

    // If constructor resolution itself failed after native marked custody,
    // retry resolution once for compensation. Failure remains fail-closed.
    late final SecretStorage storage;
    try {
      storage = _storage ?? binding.createStorage();
      await storage.delete(stateStoreDekEntry);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        mapKeybayStateCustodyError(
          error,
          action: 'remove the Tailscale state key',
        ),
        stackTrace,
      );
    }
  }

  Future<void> _awaitSettledOperation() => _custodyTail;

  void _wipeLiveBuffers() {
    for (final bytes in _liveBuffers) {
      _wipe(bytes);
    }
    _liveBuffers.clear();
  }
}

/// Materializes a transferred DEK on the caller isolate, copies it into a
/// bounded native allocation, and wipes both mutable buffers in `finally`.
@internal
void supplyTransferredDekToNative({
  required int token,
  required TransferableTypedData transferred,
  @visibleForTesting PreparedDekNativeCall? supply,
  @visibleForTesting NativeResponseFree? freeResponse,
  @visibleForTesting
  void Function(Uint8List transferred, Uint8List native)? afterWipe,
}) {
  final bytes = transferred.materialize().asUint8List();
  ffi.Pointer<ffi.Uint8>? pointer;
  try {
    _validateDek(bytes);
    pointer = calloc<ffi.Uint8>(stateStoreDekLength);
    pointer.asTypedList(stateStoreDekLength).setAll(0, bytes);
    final resultPointer = (supply ?? native.duneSupplyPreparedDek)(
      token,
      pointer,
      stateStoreDekLength,
    );
    try {
      final decoded = jsonDecode(resultPointer.toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw const TailscaleOperationException(
          'state custody',
          'Native runtime returned an invalid DEK-transfer response.',
        );
      }
      final message = decoded['error'] as String?;
      if (message != null) {
        final rawCode = decoded['code'] as String?;
        final code = TailscaleErrorCode.values.firstWhere(
          (candidate) => candidate.name == rawCode,
          orElse: () => TailscaleErrorCode.unknown,
        );
        throw TailscaleOperationException('state custody', message, code: code);
      }
    } finally {
      (freeResponse ?? native.duneFree)(resultPointer);
    }
  } finally {
    _wipe(bytes);
    if (pointer != null) {
      final nativeBytes = pointer.asTypedList(stateStoreDekLength);
      _wipe(nativeBytes);
      afterWipe?.call(bytes, nativeBytes);
      calloc.free(pointer);
    }
  }
}

void _validateDek(Uint8List key) {
  if (key.length != stateStoreDekLength) {
    throw TailscaleOperationException(
      'state custody',
      'StateStore DEK must contain exactly $stateStoreDekLength raw bytes '
          '(got ${key.length}).',
      code: TailscaleErrorCode.invalidStateKey,
    );
  }
}

void _wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);
