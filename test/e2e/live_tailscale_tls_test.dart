@Tags(['live-tailscale'])
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tailscale/tailscale.dart';
import 'package:test/test.dart';

void main() {
  final authKey = Platform.environment['TAILSCALE_AUTHKEY'];
  final controlUrl = Platform.environment['TAILSCALE_CONTROL_URL'] ??
      'https://controlplane.tailscale.com';

  if (authKey == null || authKey.isEmpty) {
    print('Skipping live Tailscale TLS test: TAILSCALE_AUTHKEY required.');
    return;
  }

  late Tailscale tsnet;
  late String stateDir;

  setUpAll(() async {
    final warmup = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--enable-experiment=native-assets',
        'test/e2e/peer_main.dart',
      ],
      environment: {
        ...Platform.environment,
        'PEER_WARMUP': '1',
      },
    );
    if (warmup.exitCode != 0) {
      throw StateError(
        'Peer warmup failed (exit ${warmup.exitCode})\n'
        'stdout: ${warmup.stdout}\nstderr: ${warmup.stderr}',
      );
    }

    stateDir = Directory.systemTemp.createTempSync('tailscale_live_tls_').path;
    Tailscale.init(stateDir: stateDir);
    tsnet = Tailscale.instance;

    if (Platform.isLinux) {
      const libPath = '.dart_tool/lib/libtailscale.so';
      final detachedPath = '$libPath.detached';
      final cp = await Process.run('cp', ['-f', libPath, detachedPath]);
      if (cp.exitCode != 0) {
        throw StateError('cp failed: ${cp.stderr}');
      }
      final mv = await Process.run('mv', [detachedPath, libPath]);
      if (mv.exitCode != 0) {
        throw StateError('mv failed: ${mv.stderr}');
      }
    }

    final status = await tsnet.up(
      hostname: 'dune-live-tls-main',
      authKey: authKey,
      controlUrl: Uri.parse(controlUrl),
    );
    if (!status.isRunning) {
      throw StateError('live node did not reach running: ${status.state}');
    }
  });

  tearDownAll(() async {
    try {
      await tsnet.down();
    } catch (_) {}
    try {
      Directory(stateDir).deleteSync(recursive: true);
    } catch (_) {}
  });

  test('tls.bind accepts a real TLS handshake over the tailnet', () async {
    final peerStateDir =
        Directory.systemTemp.createTempSync('tailscale_live_tls_peer_').path;
    final peerHostname = 'dune-live-tls-peer';
    final peer = await _PeerProcess.spawn(
      stateDir: peerStateDir,
      controlUrl: controlUrl,
      authKey: authKey,
      hostname: peerHostname,
      tlsTailnetPort: 7443,
    );
    try {
      for (var i = 0; i < 30; i++) {
        final identity = await tsnet.whois(peer.ipv4);
        if (identity != null) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      final status = await tsnet.status();
      expect(status.magicDNSSuffix, isNotEmpty,
          reason: 'live TLS test requires MagicDNS to be enabled');

      final host = '$peerHostname.${status.magicDNSSuffix}';
      final raw = await tsnet.tcp
          .dial(host, 7443, timeout: const Duration(seconds: 30))
          .timeout(const Duration(seconds: 30));
      final socket = await SecureSocket.secure(
        raw,
        host: host,
      ).timeout(const Duration(seconds: 30));

      try {
        const payload = 'live-tailnet-tls-echo';
        socket.write(payload);
        await socket.flush();

        final expected = utf8.encode(payload);
        final received = BytesBuilder();
        await for (final chunk in socket.timeout(
          const Duration(seconds: 30),
          onTimeout: (sink) => sink.close(),
        )) {
          received.add(chunk);
          if (received.length >= expected.length) break;
        }
        expect(received.takeBytes(), expected);
      } finally {
        await socket.close();
      }
    } finally {
      await peer.shutdown();
      try {
        Directory(peerStateDir).deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}

class _PeerProcess {
  _PeerProcess._(this._process, this.ipv4);

  final Process _process;
  final String ipv4;

  static Future<_PeerProcess> spawn({
    required String stateDir,
    required String controlUrl,
    required String authKey,
    required String hostname,
    required int tlsTailnetPort,
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '--enable-experiment=native-assets',
        'test/e2e/peer_main.dart',
      ],
      environment: {
        ...Platform.environment,
        'STATE_DIR': stateDir,
        'CONTROL_URL': controlUrl,
        'AUTH_KEY': authKey,
        'HOSTNAME': hostname,
        'TLS_TAILNET_PORT': '$tlsTailnetPort',
      },
    );

    unawaited(process.stderr
        .transform(utf8.decoder)
        .forEach((chunk) => stderr.write('[live peer stderr] $chunk')));

    final ready = Completer<String>();
    final readyRegex = RegExp(r'READY\s+(\S+)');
    unawaited(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      stdout.writeln('[live peer $hostname] $line');
      final match = readyRegex.firstMatch(line);
      if (match != null && !ready.isCompleted) {
        ready.complete(match.group(1)!);
      }
    }));

    final ipv4 = await ready.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw StateError('live peer "$hostname" did not become ready');
      },
    );
    return _PeerProcess._(process, ipv4);
  }

  Future<void> shutdown() async {
    try {
      await _process.stdin.close();
      await _process.exitCode.timeout(const Duration(seconds: 15));
    } catch (_) {
      _process.kill(ProcessSignal.sigterm);
    }
  }
}
