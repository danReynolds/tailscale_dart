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

const int _responseHeadPrefixBytes = 4;

/// An HTTP client that routes requests through Go's tsnet HTTP stack.
///
/// Request and response bodies are streamed over private POSIX fd capabilities
/// rather than a local TCP proxy.
final class TailscaleHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (Platform.isWindows) {
      throw const TailscaleHttpException('Windows is not supported.');
    }
    final start = _startNativeRequest(request);
    late final PosixFdTransport responseTransport;
    try {
      responseTransport = await PosixFdTransport.adopt(start.responseBodyFd);
    } catch (_) {
      closePosixFdForCleanup(start.requestBodyFd);
      closePosixFdForCleanup(start.responseBodyFd);
      rethrow;
    }

    final bodyWriteDone = _writeRequestBody(
      request.finalize(),
      start.requestBodyFd,
    );

    final parsed = _HttpResponseParser(
      responseTransport,
      request,
      bodyWriteDone,
    );
    try {
      return await parsed.response;
    } catch (_) {
      await responseTransport.close();
      rethrow;
    }
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

({int requestBodyFd, int responseBodyFd}) _startNativeRequest(
  http.BaseRequest request,
) {
  final methodPtr = request.method.toNativeUtf8();
  final urlPtr = request.url.toString().toNativeUtf8();
  final headersPtr = jsonEncode({
    for (final entry in request.headers.entries)
      entry.key: <String>[entry.value],
  }).toNativeUtf8();

  try {
    final resultPtr = native.duneHttpStart(
      methodPtr,
      urlPtr,
      headersPtr,
      request.contentLength ?? -1,
      request.followRedirects ? 1 : 0,
      request.maxRedirects,
    );
    final json = resultPtr.toDartString();
    native.duneFree(resultPtr);

    final parsed = jsonDecode(json) as Map<String, dynamic>;
    final error = parsed['error'] as String?;
    if (error != null) {
      throw TailscaleHttpException(error);
    }

    final requestBodyFd = parsed['requestBodyFd'] as int?;
    final responseBodyFd = parsed['responseBodyFd'] as int?;
    if (requestBodyFd == null || responseBodyFd == null || responseBodyFd < 0) {
      throw const TailscaleHttpException(
        'Native runtime did not return usable HTTP fds.',
      );
    }
    return (requestBodyFd: requestBodyFd, responseBodyFd: responseBodyFd);
  } finally {
    calloc.free(methodPtr);
    calloc.free(urlPtr);
    calloc.free(headersPtr);
  }
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
    final bytes = _headBytes.toBytes();
    if (_headLength == null && bytes.length >= _responseHeadPrefixBytes) {
      _headLength =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (_headLength! <= 0 || _headLength! > 16 * 1024 * 1024) {
        _fail(TailscaleHttpException('Invalid HTTP response head length.'));
        return;
      }
    }

    final headLength = _headLength;
    if (headLength == null ||
        bytes.length < _responseHeadPrefixBytes + headLength) {
      return;
    }

    final headStart = _responseHeadPrefixBytes;
    final headEnd = headStart + headLength;
    final headJson = utf8.decode(bytes.sublist(headStart, headEnd));
    final head = jsonDecode(headJson) as Map<String, dynamic>;

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
        entry.key as String: switch (entry.value) {
          final List<dynamic> values => values.join(', '),
          final String value => value,
          final Object value => value.toString(),
          null => '',
        },
  };
}
