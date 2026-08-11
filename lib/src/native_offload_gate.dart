import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:meta/meta.dart';

/// Shared bound, within the supported caller/controller isolate, for
/// short-lived helper isolates that block in synchronous FFI.
///
/// HTTP request admission shares this gate with dial, ping, and publication
/// calls. Only the native admission call holds a permit; fd-backed HTTP body
/// streaming remains independently concurrent after admission returns.
const int maxConcurrentNativeOffloads = 32;

final _nativeOffloadGate = _NativeOffloadSemaphore(maxConcurrentNativeOffloads);

/// Runs one synchronous native operation on a helper isolate under the shared
/// caller-isolate concurrency cap.
Future<T> runCappedNativeOffload<T>(FutureOr<T> Function() operation) async {
  await _nativeOffloadGate.acquire();
  try {
    return await Isolate.run(operation);
  } finally {
    _nativeOffloadGate.release();
  }
}

/// Minimal FIFO counting semaphore. Permits are released in acquire order, so
/// queued native offloads run oldest-first.
final class _NativeOffloadSemaphore {
  _NativeOffloadSemaphore(this._permits);

  int _permits;
  final _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _permits++;
    }
  }
}

/// Test seam: runs [tasks] short tasks through a fresh semaphore with the given
/// [permits] and returns the peak observed concurrency.
@visibleForTesting
Future<int> debugMaxNativeOffloadConcurrency({
  required int permits,
  required int tasks,
}) async {
  final semaphore = _NativeOffloadSemaphore(permits);
  var active = 0;
  var peak = 0;

  Future<void> task() async {
    await semaphore.acquire();
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    semaphore.release();
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < tasks; i++) task()]);
  return peak;
}
