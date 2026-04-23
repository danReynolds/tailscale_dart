import 'runtime_transport.dart';
import 'transport.dart';

final class TailscaleUdp {
  TailscaleUdp.internal(this._requireSession);

  final RuntimeTransportSession Function() _requireSession;

  Future<TailscaleDatagramPort> bind(int port) async {
    return _requireSession().bindUdp(port: port);
  }
}
