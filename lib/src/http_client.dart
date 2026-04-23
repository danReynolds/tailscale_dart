import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'worker/worker.dart';

final class TailscaleHttpRequestHead {
  const TailscaleHttpRequestHead({
    required this.method,
    required this.url,
    required this.headers,
    required this.followRedirects,
    required this.maxRedirects,
    required this.persistentConnection,
  });

  final String method;
  final Uri url;
  final Map<String, List<String>> headers;
  final bool followRedirects;
  final int maxRedirects;
  final bool persistentConnection;
}

final class TailscaleHttpResponseHead {
  const TailscaleHttpResponseHead({
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    required this.isRedirect,
    required this.finalUrl,
    required this.reasonPhrase,
    required this.connectionClose,
  });

  final int statusCode;
  final Map<String, List<String>> headers;
  final int? contentLength;
  final bool isRedirect;
  final Uri finalUrl;
  final String reasonPhrase;
  final bool connectionClose;
}

final class TailscaleHttpStream {
  const TailscaleHttpStream({
    required this.responseHead,
    required this.responseBody,
    required this.sendBodyChunk,
    required this.closeRequestBody,
    required this.cancel,
  });

  final Future<TailscaleHttpResponseHead> responseHead;
  final Stream<Uint8List> responseBody;
  final Future<void> Function(Uint8List bytes) sendBodyChunk;
  final Future<void> Function() closeRequestBody;
  final Future<void> Function() cancel;
}

/// A standard `package:http` client backed by Go's tailnet-aware HTTP client.
class TailscaleHttpClient extends http.BaseClient {
  TailscaleHttpClient.forWorker(Worker worker)
    : this.internal(openRequest: worker.openHttpRequest);

  TailscaleHttpClient.internal({
    required Future<TailscaleHttpStream> Function(TailscaleHttpRequestHead)
    openRequest,
  }) : _openRequest = openRequest;

  final Future<TailscaleHttpStream> Function(TailscaleHttpRequestHead)
  _openRequest;

  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw const TailscaleHttpException('HTTP client is closed.');
    }

    final abortTrigger = switch (request) {
      http.Abortable(:final abortTrigger?) => abortTrigger,
      _ => null,
    };

    var aborted = false;
    var responseOpened = false;
    TailscaleHttpStream? transport;

    Future<void> abortRequest() async {
      if (aborted) return;
      aborted = true;
      if (transport != null) {
        try {
          await transport.cancel();
        } catch (_) {}
      }
    }

    if (abortTrigger != null) {
      unawaited(
        abortTrigger.whenComplete(() async {
          if (!responseOpened) {
            await abortRequest();
          }
        }),
      );
    }

    final requestBody = request.finalize();
    transport = await _openRequest(
      TailscaleHttpRequestHead(
        method: request.method,
        url: request.url,
        headers: _expandHeaders(request.headers),
        followRedirects: request.followRedirects,
        maxRedirects: request.maxRedirects,
        persistentConnection: request.persistentConnection,
      ),
    );

    final bodyPump = _pumpRequestBody(
      request: request,
      requestBody: requestBody,
      transport: transport,
      isAborted: () => aborted,
      abortRequest: abortRequest,
    );

    StreamSubscription<Uint8List>? responseSubscription;
    late final StreamController<List<int>> responseController;
    responseController = StreamController<List<int>>(
      onPause: () => responseSubscription?.pause(),
      onResume: () => responseSubscription?.resume(),
      onCancel: () => responseSubscription?.cancel(),
      sync: true,
      onListen: () {
        if (aborted) {
          responseController.addError(http.RequestAbortedException(request.url));
          unawaited(responseController.close());
          return;
        }
        responseSubscription = transport!.responseBody.listen(
          responseController.add,
          onError: responseController.addError,
          onDone: () => unawaited(responseController.close()),
        );

        if (abortTrigger != null) {
          unawaited(
            abortTrigger.whenComplete(() async {
              if (responseController.isClosed) return;
              await responseSubscription?.cancel();
              await abortRequest();
              if (responseController.isClosed) return;
              responseController.addError(
                http.RequestAbortedException(request.url),
              );
              unawaited(responseController.close());
            }),
          );
        }
      },
    );

    try {
      final responseHead = await transport.responseHead;
      responseOpened = true;
      return http.StreamedResponse(
        responseController.stream,
        responseHead.statusCode,
        contentLength: responseHead.contentLength,
        request: request,
        headers: _collapseHeaders(responseHead.headers),
        isRedirect: responseHead.isRedirect,
        persistentConnection: !responseHead.connectionClose,
        reasonPhrase: responseHead.reasonPhrase,
      );
    } catch (error) {
      await bodyPump.ignore();
      if (aborted) {
        throw http.RequestAbortedException(request.url);
      }
      rethrow;
    } finally {
      unawaited(
        bodyPump.then((_) {
          if (!responseOpened && aborted) {
            unawaited(transport?.cancel());
          }
        }),
      );
    }
  }

  @override
  void close() {
    _closed = true;
  }
}

Future<void> _pumpRequestBody({
  required http.BaseRequest request,
  required Stream<List<int>> requestBody,
  required TailscaleHttpStream transport,
  required bool Function() isAborted,
  required Future<void> Function() abortRequest,
}) async {
  try {
    await for (final chunk in requestBody) {
      if (isAborted()) {
        return;
      }
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      if (bytes.isEmpty) {
        continue;
      }
      await transport.sendBodyChunk(bytes);
    }
    if (!isAborted()) {
      await transport.closeRequestBody();
    }
  } catch (error) {
    await abortRequest();
    if (error is http.RequestAbortedException) {
      rethrow;
    }
    throw TailscaleHttpException(
      'Failed while streaming the HTTP request body.',
      cause: error,
    );
  }
}

Map<String, List<String>> _expandHeaders(Map<String, String> headers) {
  return headers.map(
    (key, value) => MapEntry(key, <String>[value]),
  );
}

Map<String, String> _collapseHeaders(Map<String, List<String>> headers) {
  return headers.map(
    (key, values) => MapEntry(key, values.join(',')),
  );
}

extension on Future<void> {
  Future<void> ignore() async {
    try {
      await this;
    } catch (_) {}
  }
}
