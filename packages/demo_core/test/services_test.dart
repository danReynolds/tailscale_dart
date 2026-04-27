import 'dart:async';

import 'package:demo_core/demo_core.dart';
import 'package:http/http.dart' as http;
import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  test('startServices rebinds when the node IPv4 changes', () async {
    final tsnet = _FakeTailscale('100.64.0.10');
    final demo = DemoCore(tailscale: tsnet);

    final first = await demo.startServices();
    expect(first.localIp, '100.64.0.10');
    expect(tsnet.http.boundTailnetPorts, [demoDefaultHttpPort]);
    expect(tsnet.tcp.boundPorts, [demoDefaultTcpPort]);
    expect(tsnet.udp.boundHosts, ['100.64.0.10']);

    final same = await demo.startServices();
    expect(identical(first, same), isTrue);
    expect(tsnet.http.boundTailnetPorts, [demoDefaultHttpPort]);
    expect(tsnet.tcp.boundPorts, [demoDefaultTcpPort]);
    expect(tsnet.udp.boundHosts, ['100.64.0.10']);

    tsnet.ipv4 = '100.64.0.11';
    final rebound = await demo.startServices();
    expect(rebound.localIp, '100.64.0.11');
    expect(tsnet.http.boundTailnetPorts, [
      demoDefaultHttpPort,
      demoDefaultHttpPort,
    ]);
    expect(tsnet.http.closedBindings, 1);
    expect(tsnet.tcp.boundPorts, [demoDefaultTcpPort, demoDefaultTcpPort]);
    expect(tsnet.tcp.closedListeners, 1);
    expect(tsnet.udp.boundHosts, ['100.64.0.10', '100.64.0.11']);
    expect(tsnet.udp.closedBindings, 1);

    await demo.stopServices();
  });
}

class _FakeTailscale implements Tailscale {
  _FakeTailscale(this.ipv4);

  String ipv4;

  final _states = StreamController<NodeState>.broadcast();
  final _errors = StreamController<TailscaleRuntimeError>.broadcast();
  final _nodes = StreamController<List<TailscaleNode>>.broadcast();
  final _http = _FakeHttp();
  final _tcp = _FakeTcp();
  final _udp = _FakeUdp();

  @override
  Stream<NodeState> get onStateChange => _states.stream;

  @override
  Stream<TailscaleRuntimeError> get onError => _errors.stream;

  @override
  Stream<List<TailscaleNode>> get onNodeChanges => _nodes.stream;

  @override
  _FakeHttp get http => _http;

  @override
  _FakeTcp get tcp => _tcp;

  @override
  _FakeUdp get udp => _udp;

  @override
  Future<TailscaleStatus> status() async => TailscaleStatus(
    state: NodeState.running,
    stableNodeId: 'nFake',
    tailscaleIPs: [ipv4],
    health: const [],
  );

  @override
  Future<TailscaleStatus> up({
    String hostname = '',
    String? authKey,
    Uri? controlUrl,
    Duration timeout = const Duration(seconds: 30),
  }) => status();

  @override
  Future<List<TailscaleNode>> nodes() async => const [];

  @override
  Future<void> down() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttp implements Http {
  final boundTailnetPorts = <int>[];
  var closedBindings = 0;

  @override
  http.Client get client => throw UnimplementedError();

  @override
  Future<TailscaleHttpServer> bind({required int port}) async {
    boundTailnetPorts.add(port);
    return _FakeHttpServer(
      TailscaleEndpoint(address: '100.64.0.10', port: port),
      onClose: () => closedBindings++,
    );
  }
}

class _FakeHttpServer implements TailscaleHttpServer {
  _FakeHttpServer(this.tailnet, {required this.onClose});

  final void Function() onClose;
  final _requests = StreamController<TailscaleHttpRequest>();
  final _done = Completer<void>();
  var _closed = false;

  @override
  final TailscaleEndpoint tailnet;

  @override
  Stream<TailscaleHttpRequest> get requests => _requests.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose();
    await _requests.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class _FakeTcp implements Tcp {
  final boundPorts = <int>[];
  var closedListeners = 0;

  @override
  Future<TailscaleConnection> dial(String host, int port, {Duration? timeout}) {
    throw UnimplementedError();
  }

  @override
  Future<TailscaleListener> bind({required int port, String? address}) async {
    boundPorts.add(port);
    return _FakeListener(
      TailscaleEndpoint(address: address ?? '', port: port),
      onClose: () => closedListeners++,
    );
  }
}

class _FakeListener implements TailscaleListener {
  _FakeListener(this.local, {required this.onClose});

  final void Function() onClose;
  final _connections = StreamController<TailscaleConnection>();
  final _done = Completer<void>();
  var _closed = false;

  @override
  final TailscaleEndpoint local;

  @override
  Stream<TailscaleConnection> get connections => _connections.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose();
    await _connections.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class _FakeUdp implements Udp {
  final boundHosts = <String>[];
  var closedBindings = 0;

  @override
  Future<TailscaleDatagramBinding> bind({
    required int port,
    String? address,
  }) async {
    final resolvedAddress = address ?? '100.64.0.10';
    boundHosts.add(resolvedAddress);
    return _FakeDatagramBinding(
      TailscaleEndpoint(address: resolvedAddress, port: port),
      onClose: () => closedBindings++,
    );
  }
}

class _FakeDatagramBinding implements TailscaleDatagramBinding {
  _FakeDatagramBinding(this.local, {required this.onClose});

  final void Function() onClose;
  final _datagrams = StreamController<TailscaleDatagram>();
  final _done = Completer<void>();
  var _closed = false;

  @override
  final TailscaleEndpoint local;

  @override
  Stream<TailscaleDatagram> get datagrams => _datagrams.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(List<int> payload, {required TailscaleEndpoint to}) async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose();
    await _datagrams.close();
    if (!_done.isCompleted) _done.complete();
  }
}
