@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tailscale/src/ffi_bindings.dart' as native;

import 'support/substrate_spike.dart';

void main() {
  native.duneSetLogLevel(0);

  group('substrate spike', () {
    late SpikeHarness harness;

    setUp(() async {
      harness = await SpikeHarness.start();
    });

    tearDown(() async {
      await harness.close();
      SpikeClient.reset();
    });

    test(
      'opens an authenticated session and accepts Dart-initiated frames',
      () async {
        await harness.waitForCondition(
          () => SpikeClient.snapshot()['state'] == 'open',
        );

        final streamId = await harness.openStreamToGo(
          transport: 'tcp',
          local: {'ip': '100.64.0.1', 'port': 443},
          remote: {'ip': '100.64.0.2', 'port': 51820},
          identity: {
            'stableNodeId': 'node-123',
            'nodeName': 'peer-a',
            'userLogin': 'a@example.com',
          },
        );
        await harness.sendStreamDataToGo(streamId, utf8.encode('hello'));
        await harness.sendStreamFinToGo(streamId);

        final bindingId = await harness.openBindingToGo(
          transport: 'udp',
          local: {'ip': '100.64.0.1', 'port': 5353},
        );
        await harness.sendDatagramToGo(
          bindingId: bindingId,
          remote: {'ip': '100.64.0.9', 'port': 5353},
          data: utf8.encode('ping'),
        );

        await harness.waitForCondition(() {
          final snapshot = SpikeClient.snapshot();
          final stream = _streamSnapshot(snapshot, streamId);
          final binding = _bindingSnapshot(snapshot, bindingId);
          return stream != null &&
              (stream['receivedData'] as int) == 5 &&
              stream['receivedFin'] == true &&
              binding != null &&
              (binding['receivedDatagrams'] as int) == 1;
        });

        final snapshot = SpikeClient.snapshot();
        expect(snapshot['state'], 'open');

        final stream = _streamSnapshot(snapshot, streamId)!;
        expect(stream['receivedData'], 5);
        expect(stream['receivedFin'], isTrue);
        expect(stream['receivedRst'], isFalse);

        final binding = _bindingSnapshot(snapshot, bindingId)!;
        expect(binding['receivedDatagrams'], 1);
        expect(binding['closed'], isFalse);
        expect(binding['aborted'], isFalse);
      },
    );

    test(
      'supports concurrent streams, credit gating, FIN, RST, and GOAWAY',
      () async {
        final stream1 =
            SpikeClient.command('open_stream', {
                  'local': {'ip': '100.64.0.1', 'port': 443},
                  'remote': {'ip': '100.64.0.2', 'port': 9001},
                  'transport': 'tcp',
                  'identity': {
                    'stableNodeId': 'node-1',
                    'nodeName': 'peer-1',
                    'userLogin': 'one@example.com',
                  },
                })['streamId']
                as int;
        final stream2 =
            SpikeClient.command('open_stream', {
                  'local': {'ip': '100.64.0.1', 'port': 443},
                  'remote': {'ip': '100.64.0.3', 'port': 9002},
                  'transport': 'tcp',
                  'identity': {
                    'stableNodeId': 'node-2',
                    'nodeName': 'peer-2',
                    'userLogin': 'two@example.com',
                  },
                })['streamId']
                as int;

        await harness.waitForCondition(
          () => harness.pendingConnections.length == 2,
        );
        expect(harness.pendingConnections.map((it) => it.streamId), [
          stream1,
          stream2,
        ]);

        final largePayload = Uint8List(100 * 1024);
        for (var index = 0; index < largePayload.length; index++) {
          largePayload[index] = index % 251;
        }

        var writeCompleted = false;
        final writeFuture = SpikeClient.commandInIsolate('write_stream', {
          'streamId': stream1,
          'dataB64': _b64(largePayload),
        }).then((_) => writeCompleted = true);

        await harness.waitForCondition(
          () =>
              harness.streams[stream1]?.bytesReceived ==
              spikeInitialStreamCredit,
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(writeCompleted, isFalse);

        await harness.grantCredit(
          stream1,
          largePayload.length - spikeInitialStreamCredit,
        );
        await writeFuture;
        await harness.waitForCondition(
          () => harness.streams[stream1]?.bytesReceived == largePayload.length,
        );

        SpikeClient.command('close_write', {'streamId': stream1});
        await harness.waitForCondition(
          () => harness.streams[stream1]?.finReceived == true,
        );

        SpikeClient.command('goaway', {});
        await harness.waitForCondition(() => harness.goAwayReceived);
        expect(
          () => SpikeClient.command('open_stream', {
            'local': {'ip': '100.64.0.1', 'port': 443},
            'remote': {'ip': '100.64.0.4', 'port': 9003},
            'transport': 'tcp',
          }),
          throwsStateError,
        );

        SpikeClient.command('write_stream', {
          'streamId': stream2,
          'dataB64': _b64(utf8.encode('after-goaway')),
        });
        await harness.waitForCondition(
          () =>
              harness.streams[stream2]?.bytesReceived == 'after-goaway'.length,
        );

        SpikeClient.command('abort_stream', {'streamId': stream2});
        await harness.waitForCondition(
          () => harness.streams[stream2]?.rstReceived == true,
        );
      },
    );

    test(
      'bounds inbound listener backlog and resets overflowed opens',
      () async {
        final overflowIds = <int>[];
        for (var index = 0; index < spikeListenerBacklogLimit + 2; index++) {
          final response = SpikeClient.command('open_stream', {
            'local': {'ip': '100.64.0.1', 'port': 7000},
            'remote': {'ip': '100.64.0.2', 'port': 8000 + index},
            'transport': 'tcp',
          });
          overflowIds.add(response['streamId'] as int);
        }

        await harness.waitForCondition(() => harness.backlogDrops == 2);
        expect(
          harness.pendingConnections,
          hasLength(spikeListenerBacklogLimit),
        );

        await harness.waitForCondition(() {
          final snapshot = SpikeClient.snapshot();
          return overflowIds
                  .skip(spikeListenerBacklogLimit)
                  .where(
                    (id) =>
                        _streamSnapshot(snapshot, id)?['receivedRst'] == true,
                  )
                  .length ==
              2;
        });
      },
    );

    test(
      'bounds datagram receive queues and drops overflow datagrams',
      () async {
        final bindingId =
            SpikeClient.command('open_binding', {
                  'local': {'ip': '100.64.0.1', 'port': 5353},
                  'transport': 'udp',
                })['bindingId']
                as int;

        await harness.waitForCondition(
          () => harness.bindings.containsKey(bindingId),
        );

        for (var index = 0; index < spikeDatagramQueueLimit + 4; index++) {
          SpikeClient.command('send_datagram', {
            'bindingId': bindingId,
            'remote': {'ip': '100.64.0.9', 'port': 5353},
            'dataB64': _b64(utf8.encode('pkt-$index')),
          });
        }

        await harness.waitForCondition(() {
          final binding = harness.bindings[bindingId];
          return binding != null &&
              binding.datagrams.length == spikeDatagramQueueLimit &&
              binding.dropped == 4;
        });

        final snapshot = SpikeClient.snapshot();
        final binding = _bindingSnapshot(snapshot, bindingId)!;
        expect(binding['sentDatagrams'], spikeDatagramQueueLimit + 4);
        expect(
          harness.bindings[bindingId]!.datagrams,
          hasLength(spikeDatagramQueueLimit),
        );
        expect(harness.bindings[bindingId]!.dropped, 4);
      },
    );
  });
}

Map<String, dynamic>? _streamSnapshot(
  Map<String, dynamic> snapshot,
  int streamId,
) {
  final streams = snapshot['streams'] as List<dynamic>? ?? const <dynamic>[];
  for (final entry in streams) {
    final map = (entry as Map<Object?, Object?>).cast<String, dynamic>();
    if (map['id'] == streamId) {
      return map;
    }
  }
  return null;
}

Map<String, dynamic>? _bindingSnapshot(
  Map<String, dynamic> snapshot,
  int bindingId,
) {
  final bindings = snapshot['bindings'] as List<dynamic>? ?? const <dynamic>[];
  for (final entry in bindings) {
    final map = (entry as Map<Object?, Object?>).cast<String, dynamic>();
    if (map['id'] == bindingId) {
      return map;
    }
  }
  return null;
}

String _b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
