import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int afUnix = 1;
const int sockStream = 1;
const int sockDgram = 2;

({int leftFd, int rightFd}) socketPair(int type) {
  final fds = calloc<Int32>(2);
  try {
    final result = TestPosixBindings.instance.socketpair(afUnix, type, 0, fds);
    if (result != 0) {
      throw StateError('socketpair failed with result $result');
    }
    return (leftFd: fds[0], rightFd: fds[1]);
  } finally {
    calloc.free(fds);
  }
}

final class TestPosixBindings {
  TestPosixBindings._()
    : _socketpair = DynamicLibrary.process()
          .lookupFunction<_SocketPairNative, _SocketPairDart>('socketpair'),
      _close = DynamicLibrary.process()
          .lookupFunction<_CloseNative, _CloseDart>('close'),
      _write = DynamicLibrary.process()
          .lookupFunction<_WriteNative, _WriteDart>('write');

  static final instance = TestPosixBindings._();

  final _SocketPairDart _socketpair;
  final _CloseDart _close;
  final _WriteDart _write;

  int socketpair(int domain, int type, int protocol, Pointer<Int32> fds) =>
      _socketpair(domain, type, protocol, fds);

  int close(int fd) => _close(fd);

  int write(int fd, Uint8List bytes) {
    final pointer = calloc<Uint8>(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      return _write(fd, pointer.cast<Void>(), bytes.length);
    } finally {
      calloc.free(pointer);
    }
  }
}

typedef _SocketPairNative = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketPairDart = int Function(int, int, int, Pointer<Int32>);

typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);

typedef _WriteNative = IntPtr Function(Int32, Pointer<Void>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Void>, int);
