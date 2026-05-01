import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Handle to a `peer_main.dart` subprocess that has reached Running and
/// announced its tailnet IPv4.
final class PeerProcess {
  PeerProcess._(this._process, this.ipv4, this.hostname);

  final Process _process;
  final String ipv4;
  final String hostname;

  static Future<PeerProcess> spawn({
    required String stateDir,
    required String hostname,
    String? controlUrl,
    String? authKey,
    String? responseBody,
    List<String> advertisedRoutes = const [],
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', '--enable-experiment=native-assets', 'test/e2e/peer_main.dart'],
      environment: {
        ...Platform.environment,
        'STATE_DIR': stateDir,
        'HOSTNAME': hostname,
        if (controlUrl != null) 'CONTROL_URL': controlUrl,
        if (authKey != null) 'AUTH_KEY': authKey,
        if (responseBody != null) 'RESPONSE_BODY': responseBody,
        if (advertisedRoutes.isNotEmpty)
          'ADVERTISED_ROUTES': advertisedRoutes.join(','),
      },
    );

    unawaited(
      process.stderr
          .transform(utf8.decoder)
          .forEach((chunk) => stderr.write('[peer stderr] $chunk')),
    );

    final ready = Completer<String>();
    final readyRegex = RegExp(r'READY\s+(\S+)');
    unawaited(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            stdout.writeln('[peer $hostname] $line');
            final match = readyRegex.firstMatch(line);
            if (match != null && !ready.isCompleted) {
              ready.complete(match.group(1)!);
            }
          }),
    );

    final ipv4 = await ready.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw StateError('peer "$hostname" did not become ready within 90s');
      },
    );
    return PeerProcess._(process, ipv4, hostname);
  }

  /// Gracefully shut the peer down by closing its stdin; falls back to SIGTERM
  /// if it doesn't exit within 15 seconds.
  Future<void> shutdown() async {
    try {
      await _process.stdin.close();
      await _process.exitCode.timeout(const Duration(seconds: 15));
    } catch (_) {
      _process.kill(ProcessSignal.sigterm);
    }
  }
}
