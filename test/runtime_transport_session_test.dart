@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/runtime_transport.dart';

import 'support/runtime_transport_test_support.dart';

void main() {
  group('RuntimeTransportSession', () {
    test('does not open before SESSION_CONFIRM validates', () async {
      final bootstrap = runtimeTransportTestBootstrap();
      final releaseConfirm = Completer<void>();
      final releaseServer = Completer<void>();
      final serverDone = Completer<void>();

      final delegate = FakeRuntimeTransportDelegate(
        onAttach:
            ({required host, required port, required listenerOwner}) async {
              final socket = await Socket.connect(host, port);
              try {
                await performGoHandshake(
                  socket: socket,
                  bootstrap: bootstrap,
                  listenerOwner: listenerOwner,
                  beforeConfirm: () => releaseConfirm.future,
                );
                await releaseServer.future;
              } finally {
                await socket.close();
                serverDone.complete();
              }
            },
      );

      var completed = false;
      final startFuture =
          RuntimeTransportSession.start(
            bootstrap: bootstrap,
            worker: delegate,
            publishRuntimeError: (_) {},
          ).then((session) {
            completed = true;
            return session;
          });

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(completed, isFalse);

      releaseConfirm.complete();
      final session = await startFuture.timeout(const Duration(seconds: 2));
      await session.close();
      releaseServer.complete();
      await serverDone.future.timeout(const Duration(seconds: 2));
    });

    test('rejects a non-confirm first post-handshake frame', () async {
      final bootstrap = runtimeTransportTestBootstrap();

      final delegate = FakeRuntimeTransportDelegate(
        onAttach:
            ({required host, required port, required listenerOwner}) async {
              final socket = await Socket.connect(host, port);
              try {
                await performGoHandshake(
                  socket: socket,
                  bootstrap: bootstrap,
                  listenerOwner: listenerOwner,
                  firstFrameOverride: const FrameSpec(
                    kind: 10,
                    payload: <int>[],
                  ),
                );
              } finally {
                await socket.close();
              }
            },
      );

      await expectLater(
        RuntimeTransportSession.start(
          bootstrap: bootstrap,
          worker: delegate,
          publishRuntimeError: (_) {},
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.message,
            'message',
            contains('Expected SESSION_CONFIRM as first post-handshake frame'),
          ),
        ),
      );
    });

    test(
      'stale CLIENT_HELLO without live SESSION_CONFIRM cannot create a session',
      () async {
        final bootstrap = runtimeTransportTestBootstrap();

        final delegate = FakeRuntimeTransportDelegate(
          onAttach:
              ({required host, required port, required listenerOwner}) async {
                final socket = await Socket.connect(host, port);
                try {
                  await performGoHandshake(
                    socket: socket,
                    bootstrap: bootstrap,
                    listenerOwner: listenerOwner,
                    skipConfirm: true,
                  );
                } finally {
                  await socket.close();
                }
              },
        );

        await expectLater(
          RuntimeTransportSession.start(
            bootstrap: bootstrap,
            worker: delegate,
            publishRuntimeError: (_) {},
          ),
          throwsA(
            isA<TailscaleUpException>().having(
              (error) => error.message,
              'message',
              contains('Transport carrier closed before session confirmation'),
            ),
          ),
        );
      },
    );

    test('rejects unsupported advertised session versions', () async {
      final bootstrap = runtimeTransportTestBootstrap();

      final delegate = FakeRuntimeTransportDelegate(
        onAttach:
            ({required host, required port, required listenerOwner}) async {
              final socket = await Socket.connect(host, port);
              try {
                await performGoHandshake(
                  socket: socket,
                  bootstrap: bootstrap,
                  listenerOwner: listenerOwner,
                  sessionVersions: const <int>[2],
                  skipConfirm: true,
                );
              } finally {
                await socket.close();
              }
            },
      );

      await expectLater(
        RuntimeTransportSession.start(
          bootstrap: bootstrap,
          worker: delegate,
          publishRuntimeError: (_) {},
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.message,
            'message',
            contains('No supported transport protocol version'),
          ),
        ),
      );
    });

    test('accepts advertised version lists that include v1', () async {
      final bootstrap = runtimeTransportTestBootstrap();

      final delegate = FakeRuntimeTransportDelegate(
        onAttach:
            ({required host, required port, required listenerOwner}) async {
              final socket = await Socket.connect(host, port);
              try {
                await performGoHandshake(
                  socket: socket,
                  bootstrap: bootstrap,
                  listenerOwner: listenerOwner,
                  sessionVersions: const <int>[2, 1],
                );
              } finally {
                await socket.close();
              }
            },
      );

      final session = await RuntimeTransportSession.start(
        bootstrap: bootstrap,
        worker: delegate,
        publishRuntimeError: (_) {},
      );
      await session.close();
    });

    test('rejects non-empty requested capabilities', () async {
      final bootstrap = runtimeTransportTestBootstrap();

      final delegate = FakeRuntimeTransportDelegate(
        onAttach:
            ({required host, required port, required listenerOwner}) async {
              final socket = await Socket.connect(host, port);
              try {
                await performGoHandshake(
                  socket: socket,
                  bootstrap: bootstrap,
                  listenerOwner: listenerOwner,
                  requestedCapabilities: const <String>['future-cap'],
                  skipConfirm: true,
                );
              } finally {
                await socket.close();
              }
            },
      );

      await expectLater(
        RuntimeTransportSession.start(
          bootstrap: bootstrap,
          worker: delegate,
          publishRuntimeError: (_) {},
        ),
        throwsA(
          isA<TailscaleUpException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported requested transport capabilities'),
          ),
        ),
      );
    });
  });
}
