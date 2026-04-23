abstract interface class RuntimeTransportDelegate {
  Future<void> attachTransport({
    required String host,
    required int port,
    required String listenerOwner,
  });

  Future<void> tcpUnbind({required int port});

  Future<int> tcpDial({required String host, required int port});

  Future<int> udpBind({required int port});
}
