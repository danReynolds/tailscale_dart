import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'errors.dart';
import 'fd_transport.dart';
import 'ffi_bindings.dart' as native;
import 'http_fd_protocol.dart';
import 'native_offload_gate.dart';
import 'native_error_code.dart';

const int _responseHeadPrefixBytes = 4;

/// An HTTP client that routes requests through Go's tsnet HTTP stack.
///
/// Request and response bodies are streamed over private POSIX fd capabilities
/// rather than a local TCP proxy.
final class TailscaleHttpClient extends http.BaseClient {
  TailscaleHttpClient({required this.runtimeToken});

  /// Exact native runtime capability captured when this client was created.
  final int runtimeToken;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException(
        'Tailscale HTTP client is closed.',
        request.url,
      );
    }
    if (Platform.isWindows) {
      throw const TailscaleHttpException('Windows is not supported.');
    }
    final nativeRequest = _NativeHttpRequest.fromRequest(request);
    // The native readiness gate can join the one bounded first-Up bootstrap.
    // Keep that synchronous FFI wait off the caller's event-loop isolate.
    final start = await runCappedNativeOffload(
      () => _startNativeRequest(runtimeToken, nativeRequest),
    );
    if (_closed) {
      closePosixFdForCleanup(start.requestBodyFd);
      closePosixFdForCleanup(start.responseBodyFd);
      throw http.ClientException(
        'Tailscale HTTP client is closed.',
        request.url,
      );
    }
    return _sendOverFds(
      requestBodyFd: start.requestBodyFd,
      responseBodyFd: start.responseBodyFd,
      request: request,
    );
  }

  @override
  void close() {
    _closed = true;
  }
}

final class _NativeHttpRequest {
  const _NativeHttpRequest({
    required this.method,
    required this.url,
    required this.headersJson,
    required this.contentLength,
    required this.followRedirects,
    required this.maxRedirects,
  });

  factory _NativeHttpRequest.fromRequest(http.BaseRequest request) =>
      _NativeHttpRequest(
        method: request.method,
        url: request.url.toString(),
        headersJson: jsonEncode({
          for (final entry in request.headers.entries)
            entry.key: <String>[entry.value],
        }),
        contentLength: request.contentLength ?? -1,
        followRedirects: request.followRedirects,
        maxRedirects: request.maxRedirects,
      );

  final String method;
  final String url;
  final String headersJson;
  final int contentLength;
  final bool followRedirects;
  final int maxRedirects;
}

/// Drives [request] over the two native fds and returns the streamed response.
///
/// Owns both fds once called: [responseBodyFd] is adopted into a transport
/// (which closes it itself on adopt-failure), and [requestBodyFd] is handed to
/// [_writeRequestBody] (which adopts and closes it). A single cleanup path
/// releases whatever is still owned if any step throws — ownership is tracked
/// by the [requestFdTransferred] flag rather than by code position, so a future
/// inserted step can't silently leak an fd (and pin the Go request goroutine).
/// Mirrors the inbound accept path's cleanup shape in `api/http.dart`.
Future<http.StreamedResponse> _sendOverFds({
  required int requestBodyFd,
  required int responseBodyFd,
  required http.BaseRequest request,
}) async {
  PosixFdTransport? responseTransport;
  var requestFdTransferred = false;
  try {
    // adopt closes responseBodyFd itself if it throws.
    responseTransport = await PosixFdTransport.adopt(responseBodyFd);

    // finalize() can throw (a re-sent request, or a custom BaseRequest
    // override) before the request fd is adopted.
    final requestBody = request.finalize();

    // From here _writeRequestBody owns (adopts + closes) the request fd.
    requestFdTransferred = true;
    final bodyWriteDone = _writeRequestBody(requestBody, requestBodyFd);

    return await _HttpResponseParser(
      responseTransport,
      request,
      bodyWriteDone,
    ).response;
  } catch (_) {
    await responseTransport?.close();
    if (!requestFdTransferred) closePosixFdForCleanup(requestBodyFd);
    rethrow;
  }
}

@visibleForTesting
Future<http.StreamedResponse> parseHttpFdResponseForTesting({
  required PosixFdTransport responseTransport,
  required http.BaseRequest request,
  required Future<void> requestBodyDone,
}) {
  return _HttpResponseParser(
    responseTransport,
    request,
    requestBodyDone,
  ).response;
}

/// Test seam over [_writeRequestBody]: streams [body] to [fd] chunk-by-chunk.
/// Exposed so a regression test can prove the request body is transmitted
/// incrementally rather than buffered in full before the first write.
@visibleForTesting
Future<void> writeRequestBodyForTesting(Stream<List<int>> body, int fd) =>
    _writeRequestBody(body, fd);

/// Test seam over [_sendOverFds]: drives the fd-owning core directly on
/// caller-supplied fds, so a fault-injection test can prove both fds are
/// released when a step (e.g. `request.finalize()`) throws.
@visibleForTesting
Future<http.StreamedResponse> sendOverFdsForTesting({
  required int requestBodyFd,
  required int responseBodyFd,
  required http.BaseRequest request,
}) => _sendOverFds(
  requestBodyFd: requestBodyFd,
  responseBodyFd: responseBodyFd,
  request: request,
);

({int requestBodyFd, int responseBodyFd}) _startNativeRequest(
  int runtimeToken,
  _NativeHttpRequest request,
) {
  final methodPtr = request.method.toNativeUtf8();
  final urlPtr = request.url.toNativeUtf8();
  final headersPtr = request.headersJson.toNativeUtf8();

  try {
    final resultPtr = native.duneHttpStart(
      runtimeToken,
      methodPtr,
      urlPtr,
      headersPtr,
      request.contentLength,
      request.followRedirects ? 1 : 0,
      request.maxRedirects,
    );
    late final String json;
    try {
      json = resultPtr.toDartString();
    } finally {
      native.duneFree(resultPtr);
    }

    final parsed = jsonDecode(json) as Map<String, dynamic>;
    final error = parsed['error'] as String?;
    if (error != null) {
      throw TailscaleHttpException(
        error,
        code: parseNativeErrorCode(parsed['code'] as String?),
        statusCode: parsed['statusCode'] as int?,
      );
    }

    return validateNativeHttpFdsForTesting(
      requestBodyFd: parsed['requestBodyFd'],
      responseBodyFd: parsed['responseBodyFd'],
    );
  } finally {
    calloc.free(methodPtr);
    calloc.free(urlPtr);
    calloc.free(headersPtr);
  }
}

/// Validates and assumes ownership of the native HTTP fd pair.
///
/// Native is expected to return either `-1` for an absent request body or a
/// non-negative request fd, plus a non-negative response fd. If that contract
/// is violated after native has already created one usable descriptor, close
/// every descriptor Dart can identify before surfacing the protocol error.
@visibleForTesting
({int requestBodyFd, int responseBodyFd}) validateNativeHttpFdsForTesting({
  required Object? requestBodyFd,
  required Object? responseBodyFd,
  void Function(int) closeFd = closePosixFdForCleanup,
}) {
  if (requestBodyFd is int &&
      requestBodyFd >= -1 &&
      responseBodyFd is int &&
      responseBodyFd >= 0) {
    return (requestBodyFd: requestBodyFd, responseBodyFd: responseBodyFd);
  }

  final ownedFds = <int>{
    if (requestBodyFd is int && requestBodyFd >= 0) requestBodyFd,
    if (responseBodyFd is int && responseBodyFd >= 0) responseBodyFd,
  };
  for (final fd in ownedFds) {
    closeFd(fd);
  }
  throw const TailscaleHttpException(
    'Native runtime did not return usable HTTP fds.',
  );
}

Future<void> _writeRequestBody(Stream<List<int>> body, int fd) async {
  if (fd < 0) {
    await body.drain<void>();
    return;
  }

  final transport = await PosixFdTransport.adopt(fd);
  try {
    await for (final chunk in body) {
      if (chunk.isEmpty) continue;
      await transport.write(
        chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      );
    }
    await transport.closeWrite();
  } finally {
    await transport.close();
  }
}

final class _HttpResponseParser {
  _HttpResponseParser(
    this._transport,
    this._request,
    Future<void> requestBodyDone,
  ) {
    _body = StreamController<List<int>>(
      onPause: () => _subscription.pause(),
      onResume: () => _subscription.resume(),
      onCancel: _transport.close,
    );
    _subscription = _transport.input.listen(
      _handleChunk,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: true,
    );
    unawaited(
      requestBodyDone.then(
        (_) {
          _requestBodyDone = true;
          _maybeCloseBody();
        },
        onError: (Object error, StackTrace stackTrace) {
          _handleRequestBodyError(error, stackTrace);
        },
      ),
    );
  }

  final PosixFdTransport _transport;
  final http.BaseRequest _request;
  final _response = Completer<http.StreamedResponse>();
  final _headBytes = BytesBuilder(copy: false);
  late final StreamController<List<int>> _body;
  late final StreamSubscription<Uint8List> _subscription;
  int? _headLength;
  bool _headComplete = false;
  bool _responseBodyDone = false;
  bool _requestBodyDone = false;

  Future<http.StreamedResponse> get response => _response.future;

  void _handleChunk(Uint8List chunk) {
    if (_headComplete) {
      _body.add(chunk);
      return;
    }

    _headBytes.add(chunk);
    // Materialize the accumulated bytes O(1) times rather than once per chunk:
    // once to read the 4-byte length prefix, and once more when the full head
    // has arrived. `BytesBuilder.length` is O(1), so the waiting chunks don't
    // re-copy the buffer.
    if (_headBytes.length < _responseHeadPrefixBytes) return;

    if (_headLength == null) {
      final bytes = _headBytes.toBytes();
      _headLength =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (_headLength! <= 0 || _headLength! > tailscaleMaxHttpHeadBytes) {
        _fail(
          const TailscaleHttpException('Invalid HTTP response head length.'),
        );
        return;
      }
      // Reuse this materialization if it already holds the complete head
      // (the common single-chunk case).
      if (bytes.length >= _responseHeadPrefixBytes + _headLength!) {
        _completeHead(bytes);
      }
      return;
    }

    if (_headBytes.length < _responseHeadPrefixBytes + _headLength!) return;
    _completeHead(_headBytes.toBytes());
  }

  void _completeHead(Uint8List bytes) {
    final headStart = _responseHeadPrefixBytes;
    final headEnd = headStart + _headLength!;
    final Map<String, dynamic> head;
    try {
      final headJson = utf8.decode(
        Uint8List.sublistView(bytes, headStart, headEnd),
      );
      head = jsonDecode(headJson) as Map<String, dynamic>;
    } catch (error, stackTrace) {
      _fail(
        TailscaleHttpException('Invalid HTTP response head: $error'),
        stackTrace,
      );
      return;
    }

    final error = head['error'] as String?;
    if (error != null) {
      _fail(http.ClientException(error, _request.url));
      return;
    }

    final statusCode = head['statusCode'] as int?;
    if (statusCode == null || statusCode < 100 || statusCode > 999) {
      _fail(const TailscaleHttpException('Invalid HTTP response status.'));
      return;
    }

    _headComplete = true;
    _response.complete(
      http.StreamedResponse(
        _body.stream,
        statusCode,
        contentLength: _parseContentLength(head['contentLength']),
        request: _request,
        headers: _parseHeaders(head['headers']),
        reasonPhrase: head['reasonPhrase'] as String?,
      ),
    );

    if (headEnd < bytes.length) {
      _body.add(Uint8List.sublistView(bytes, headEnd));
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _fail(error, stackTrace);
  }

  void _handleDone() {
    if (!_headComplete) {
      _fail(
        const TailscaleHttpException('HTTP response closed before header.'),
      );
      return;
    }
    _responseBodyDone = true;
    _maybeCloseBody();
  }

  void _handleRequestBodyError(Object error, StackTrace stackTrace) {
    if (!_headComplete) {
      _fail(error, stackTrace);
      return;
    }
    if (!_body.isClosed) {
      _body.addError(error, stackTrace);
      unawaited(_body.close());
    }
    unawaited(_subscription.cancel());
    unawaited(_transport.close());
  }

  void _maybeCloseBody() {
    if (!_headComplete || !_responseBodyDone || !_requestBodyDone) return;
    if (!_body.isClosed) unawaited(_body.close());
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (!_response.isCompleted) {
      _response.completeError(error, stackTrace);
    }
    if (!_body.isClosed) {
      _body.addError(error, stackTrace);
      unawaited(_body.close());
    }
    unawaited(_subscription.cancel());
    unawaited(_transport.close());
  }
}

int? _parseContentLength(Object? value) {
  if (value is int && value >= 0) return value;
  return null;
}

Map<String, String> _parseHeaders(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (entry.key is String)
        // Lowercase the key: the Go side forwards `resp.Header` verbatim, whose
        // keys are canonical-cased ("Content-Type"), but `package:http` looks
        // headers up by their lowercase name (e.g. `Response.body` reads
        // `headers['content-type']` to pick the charset). Without this a
        // UTF-8 `application/json; charset=utf-8` body decodes as latin1, and
        // any lowercase header lookup silently misses.
        (entry.key as String).toLowerCase(): switch (entry.value) {
          final List<dynamic> values => values.join(', '),
          final String value => value,
          final Object value => value.toString(),
          null => '',
        },
  };
}
