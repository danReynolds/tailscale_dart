import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../errors.dart';

@internal
Http createHttp({
  required http.Client? Function() clientGetter,
  required Future<int> Function(int localPort, int tailnetPort) exposeFn,
}) =>
    _Http(
      clientGetter: clientGetter,
      exposeFn: exposeFn,
    );

/// HTTP-specific conveniences layered on top of [Tailscale.tcp].
///
/// Reached via [Tailscale.http].
abstract class Http {
  /// An [http.Client] where every request routes over the tailnet.
  ///
  /// Drop-in replacement for a regular `http.Client`. Available after
  /// [Tailscale.up] completes; throws [TailscaleUsageException] before.
  http.Client get client;

  /// Forwards tailnet HTTP traffic on [tailnetPort] to a local HTTP server
  /// on `127.0.0.1:<localPort>`. Returns the effective local port
  /// (identical to [localPort] unless [localPort] was `0`, in which case
  /// an ephemeral port is allocated and returned).
  ///
  /// Replaces the previous top-level `Tailscale.listen`.
  Future<int> expose(int localPort, {int tailnetPort = 80});
}

final class _Http implements Http {
  _Http({
    required http.Client? Function() clientGetter,
    required Future<int> Function(int localPort, int tailnetPort) exposeFn,
  })  : _clientGetter = clientGetter,
        _exposeFn = exposeFn;

  final http.Client? Function() _clientGetter;
  final Future<int> Function(int localPort, int tailnetPort) _exposeFn;

  @override
  http.Client get client {
    final c = _clientGetter();
    if (c == null) {
      throw const TailscaleUsageException(
        'Call Tailscale.instance.up() before accessing http.client.',
      );
    }
    return c;
  }

  @override
  Future<int> expose(int localPort, {int tailnetPort = 80}) =>
      _exposeFn(localPort, tailnetPort);
}
