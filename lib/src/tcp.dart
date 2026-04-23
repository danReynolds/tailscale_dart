import 'runtime_transport.dart';
import 'transport.dart';
import 'worker/worker.dart';

final class TailscaleTcp {
  TailscaleTcp.internal(this._requireSession, this._worker);

  final RuntimeTransportSession Function() _requireSession;
  final Worker _worker;

  Future<TailscaleConnection> dial(String host, int port) async {
    return _requireSession().dialTcp(host: host, port: port);
  }

  Future<TailscaleListener> bind(int port) async {
    final session = _requireSession();
    final listener = session.registerListener(port);
    try {
      await _worker.tcpBind(port: port);
      return listener;
    } catch (_) {
      await listener.close();
      rethrow;
    }
  }
}
