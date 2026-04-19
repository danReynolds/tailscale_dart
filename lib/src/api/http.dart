import 'package:http/http.dart' as http;

/// HTTP-specific conveniences layered on top of [Tailscale.tcp].
///
/// Reached via [Tailscale.http].
class Http {
  const Http();

  /// An [http.Client] where every request routes over the tailnet.
  ///
  /// Drop-in replacement for a regular `http.Client`. Available after
  /// [Tailscale.up] completes.
  http.Client get client =>
      throw UnimplementedError('http.client not yet implemented');

  /// Forwards tailnet HTTP traffic on [tailnetPort] to a local HTTP server
  /// on `127.0.0.1:<localPort>`. Returns the effective local port.
  ///
  /// Replaces the previous top-level `Tailscale.listen`.
  Future<int> expose(int localPort, {int tailnetPort = 80}) =>
      throw UnimplementedError('http.expose not yet implemented');
}
