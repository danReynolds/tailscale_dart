import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Transport endpoint metadata attached by the runtime transport layer.
final class TailscaleEndpoint {
  const TailscaleEndpoint({required this.ip, required this.port});

  final InternetAddress ip;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is TailscaleEndpoint &&
      other.ip.address == ip.address &&
      other.port == port;

  @override
  int get hashCode => Object.hash(ip.address, port);

  @override
  String toString() => 'TailscaleEndpoint(${ip.address}:$port)';
}

/// Immutable authenticated peer identity attached by the transport authority.
final class TailscaleIdentity {
  const TailscaleIdentity({
    this.stableNodeId,
    this.nodeName,
    this.userLogin,
    this.userDisplayName,
  });

  final String? stableNodeId;
  final String? nodeName;
  final String? userLogin;
  final String? userDisplayName;

  @override
  bool operator ==(Object other) =>
      other is TailscaleIdentity &&
      other.stableNodeId == stableNodeId &&
      other.nodeName == nodeName &&
      other.userLogin == userLogin &&
      other.userDisplayName == userDisplayName;

  @override
  int get hashCode =>
      Object.hash(stableNodeId, nodeName, userLogin, userDisplayName);

  @override
  String toString() {
    return 'TailscaleIdentity(stableNodeId: $stableNodeId, nodeName: $nodeName, userLogin: $userLogin, userDisplayName: $userDisplayName)';
  }
}

/// Writable half of a logical tailnet transport connection.
abstract interface class TailscaleWriter {
  Future<void> write(Uint8List bytes);
  Future<void> writeAll(Stream<List<int>> source);
  Future<void> close();
  Future<void> get done;
}

/// Logical bidirectional tailnet transport connection.
abstract interface class TailscaleConnection {
  TailscaleEndpoint get local;
  TailscaleEndpoint get remote;
  TailscaleIdentity? get identity;

  Stream<Uint8List> get input;
  TailscaleWriter get output;

  Future<void> close();
  void abort([Object? error, StackTrace? stackTrace]);
  Future<void> get done;
}

/// Listener that yields accepted tailnet transport connections.
abstract interface class TailscaleListener {
  Stream<TailscaleConnection> get connections;
  Future<void> close();
  Future<void> get done;
}

/// One immutable datagram delivery on a tailnet datagram binding.
final class TailscaleDatagram {
  const TailscaleDatagram({
    required this.bytes,
    required this.local,
    required this.remote,
    this.identity,
  });

  final Uint8List bytes;
  final TailscaleEndpoint local;
  final TailscaleEndpoint remote;
  final TailscaleIdentity? identity;

  @override
  bool operator ==(Object other) =>
      other is TailscaleDatagram &&
      _bytesEqual(other.bytes, bytes) &&
      other.local == local &&
      other.remote == remote &&
      other.identity == identity;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(bytes), local, remote, identity);

  @override
  String toString() {
    return 'TailscaleDatagram(bytes: ${bytes.length}, local: $local, remote: $remote, identity: $identity)';
  }
}

/// Datagram transport binding with preserved message boundaries.
abstract interface class TailscaleDatagramPort {
  TailscaleEndpoint get local;

  Stream<TailscaleDatagram> get datagrams;

  Future<void> send(Uint8List bytes, {required TailscaleEndpoint remote});

  Future<void> close();
  void abort([Object? error, StackTrace? stackTrace]);
  Future<void> get done;
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
