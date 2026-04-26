import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../errors.dart';
import '../fd_transport.dart';
import '../ffi_bindings.dart' as native;
import '../http_fd_protocol.dart';
import 'connection.dart';

const int _maxPendingHttpAccepts = 128;

typedef HttpBindFn =
    Future<({int bindingId, TailscaleEndpoint tailnet})> Function(int port);
typedef HttpCloseBindingFn = Future<void> Function(int bindingId);

@internal
Http createHttp({
  required http.Client? Function() clientGetter,
  required HttpBindFn bindFn,
  required HttpCloseBindingFn closeBindingFn,
}) => _Http(
  clientGetter: clientGetter,
  bindFn: bindFn,
  closeBindingFn: closeBindingFn,
);

@visibleForTesting
TailscaleHttpRequest createHttpRequestForTesting({
  String method = 'GET',
  String requestUri = '/',
  String host = '',
  String protocolVersion = 'HTTP/1.1',
  Map<String, List<String>> headersAll = const {},
  int? contentLength,
  TailscaleEndpoint remote = const TailscaleEndpoint(
    address: '100.64.0.2',
    port: 1,
  ),
  TailscaleEndpoint local = const TailscaleEndpoint(
    address: '100.64.0.1',
    port: 80,
  ),
  required PosixFdTransport requestTransport,
  required PosixFdTransport responseTransport,
}) => _TailscaleHttpRequest(
  method: method,
  requestUri: requestUri,
  host: host,
  protocolVersion: protocolVersion,
  headersAll: headersAll,
  contentLength: contentLength,
  remote: remote,
  local: local,
  requestTransport: requestTransport,
  responseTransport: responseTransport,
);

/// HTTP-specific conveniences routed through the embedded tailnet node.
///
/// Reached via [Tailscale.http].
abstract class Http {
  /// An [http.Client] where every request routes over the tailnet.
  ///
  /// Drop-in replacement for a regular `http.Client`. Available after
  /// [Tailscale.up] completes; throws [TailscaleUsageException] before.
  http.Client get client;

  /// Binds a tailnet HTTP port and exposes inbound requests as fd-backed Dart
  /// request objects.
  ///
  /// The native accept backlog is bounded. If the Dart side falls behind far
  /// enough for the Go-side backlog to fill, new wire clients receive HTTP 503.
  Future<TailscaleHttpServer> bind({required int port});
}

/// A live tailnet HTTP server.
abstract interface class TailscaleHttpServer {
  /// Tailnet endpoint where other nodes can reach this HTTP server.
  TailscaleEndpoint get tailnet;

  /// Single-subscription stream of inbound HTTP requests.
  Stream<TailscaleHttpRequest> get requests;

  /// Stops accepting new HTTP requests.
  Future<void> close();

  /// Completes when [close] has completed.
  Future<void> get done;
}

/// One inbound HTTP request accepted from the tailnet.
abstract interface class TailscaleHttpRequest {
  String get method;
  Uri get uri;
  String get requestUri;
  String get host;
  String get protocolVersion;
  int? get contentLength;
  Map<String, String> get headers;
  Map<String, List<String>> get headersAll;
  TailscaleEndpoint get local;
  TailscaleEndpoint get remote;

  /// Single-subscription request body stream.
  ///
  /// Like Shelf and `dart:io` request bodies, this can be consumed once. If a
  /// handler needs to inspect the body in multiple places, buffer it explicitly
  /// in application code.
  Stream<Uint8List> get body;
  TailscaleHttpResponse get response;

  /// Convenience helper for complete non-hijacked responses.
  Future<void> respond({
    int statusCode = 200,
    Map<String, String>? headers,
    Object? body,
  });
}

/// Writable response half for a [TailscaleHttpRequest].
abstract interface class TailscaleHttpResponse {
  int get statusCode;
  set statusCode(int value);

  /// Mutable headers. Mutations after the first body write are not sent.
  Map<String, String> get headers;

  /// Snapshot of all configured response headers, including repeated values.
  Map<String, List<String>> get headersAll;

  /// Replaces all values for [name] with [value].
  void setHeader(String name, String value);

  /// Appends one value for [name].
  void addHeader(String name, String value);

  Future<void> write(List<int> bytes);
  Future<void> writeString(String text, {Encoding encoding = utf8});
  Future<void> writeAll(Stream<List<int>> chunks, {bool close = false});
  Future<void> close();
  Future<void> get done;
}

final class _Http implements Http {
  _Http({
    required http.Client? Function() clientGetter,
    required HttpBindFn bindFn,
    required HttpCloseBindingFn closeBindingFn,
  }) : _clientGetter = clientGetter,
       _bindFn = bindFn,
       _closeBindingFn = closeBindingFn;

  final http.Client? Function() _clientGetter;
  final HttpBindFn _bindFn;
  final HttpCloseBindingFn _closeBindingFn;

  @override
  http.Client get client {
    if (Platform.isWindows) {
      throw const TailscaleHttpException('Windows is not supported.');
    }
    final c = _clientGetter();
    if (c == null) {
      throw const TailscaleUsageException(
        'Call Tailscale.instance.up() before accessing http.client.',
      );
    }
    return c;
  }

  @override
  Future<TailscaleHttpServer> bind({required int port}) async {
    if (Platform.isWindows) {
      throw const TailscaleHttpException('Windows is not supported.');
    }
    try {
      final binding = await _bindFn(port);
      return _FdTailscaleHttpServer(
        bindingId: binding.bindingId,
        tailnet: binding.tailnet,
        closeFn: _closeBindingFn,
      );
    } catch (e) {
      if (e is TailscaleHttpException) rethrow;
      throw TailscaleHttpException(
        'http.bind failed for tailnet port $port',
        cause: e,
      );
    }
  }
}

final class _FdTailscaleHttpServer implements TailscaleHttpServer {
  _FdTailscaleHttpServer({
    required this.bindingId,
    required this.tailnet,
    required Future<void> Function(int bindingId) closeFn,
  }) : _closeFn = closeFn {
    _requests = StreamController<TailscaleHttpRequest>(
      onListen: _startAcceptLoop,
      onResume: _drainPendingAccepts,
      onCancel: close,
    );
  }

  final int bindingId;
  final Future<void> Function(int bindingId) _closeFn;
  final _done = Completer<void>();
  late final StreamController<TailscaleHttpRequest> _requests;
  final _pendingAccepts = Queue<_PendingHttpAccept>();
  ReceivePort? _acceptEvents;
  Isolate? _acceptIsolate;
  bool _closed = false;

  @override
  final TailscaleEndpoint tailnet;

  @override
  Stream<TailscaleHttpRequest> get requests => _requests.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return done;
    _closed = true;
    try {
      await _closeFn(bindingId);
      _acceptIsolate?.kill(priority: Isolate.immediate);
      _acceptEvents?.close();
      _closePendingAccepts();
      if (!_requests.isClosed) unawaited(_requests.close());
      if (!_done.isCompleted) _done.complete();
    } catch (error, stackTrace) {
      if (!_done.isCompleted) _done.completeError(error, stackTrace);
      rethrow;
    }
    return done;
  }

  void _startAcceptLoop() {
    if (_closed || _acceptEvents != null) return;
    final events = ReceivePort();
    _acceptEvents = events;
    events.listen(_handleAcceptEvent);
    unawaited(() async {
      try {
        _acceptIsolate = await Isolate.spawn(_httpAcceptLoop, <Object>[
          bindingId,
          events.sendPort,
        ], debugName: 'tailscale-http-accept-$bindingId');
      } catch (error, stackTrace) {
        if (!_requests.isClosed) {
          _requests.addError(error, stackTrace);
          await close();
        }
      }
    }());
  }

  void _handleAcceptEvent(Object? message) {
    if (_closed) return;
    if (message == null) {
      unawaited(close());
      return;
    }
    if (message is List && message.isNotEmpty && message[0] == 'error') {
      final detail = message.length > 1 ? message[1] : 'unknown error';
      _requests.addError(TailscaleHttpException('$detail'));
      unawaited(close());
      return;
    }
    if (message is! List || message.length != 14 || message[0] != 'accepted') {
      return;
    }

    final requestBodyFd = message[1] as int;
    final responseBodyFd = message[2] as int;
    final accept = _PendingHttpAccept(
      requestBodyFd: requestBodyFd,
      responseBodyFd: responseBodyFd,
      method: message[3] as String,
      requestUri: message[4] as String,
      host: message[5] as String,
      protocolVersion: message[6] as String,
      headersAll: _copyHeadersAll(message[7]),
      contentLength: _parseNullableContentLength(message[8]),
      remote: TailscaleEndpoint(
        address: message[9] as String,
        port: message[10] as int,
      ),
      local: TailscaleEndpoint(
        address: message[11] as String,
        port: message[12] as int,
      ),
    );
    if (_requests.isPaused || _pendingAccepts.isNotEmpty) {
      _enqueueAccepted(accept);
      return;
    }
    _deliverAccepted(accept);
  }

  void _enqueueAccepted(_PendingHttpAccept accept) {
    if (_pendingAccepts.length >= _maxPendingHttpAccepts) {
      accept.close();
      return;
    }
    _pendingAccepts.addLast(accept);
  }

  void _drainPendingAccepts() {
    while (!_closed && !_requests.isPaused && _pendingAccepts.isNotEmpty) {
      _deliverAccepted(_pendingAccepts.removeFirst());
    }
  }

  void _deliverAccepted(_PendingHttpAccept accept) {
    unawaited(() async {
      PosixFdTransport? requestTransport;
      PosixFdTransport? responseTransport;
      try {
        requestTransport = await PosixFdTransport.adopt(accept.requestBodyFd);
        responseTransport = await PosixFdTransport.adopt(accept.responseBodyFd);
        final request = _TailscaleHttpRequest(
          method: accept.method,
          requestUri: accept.requestUri,
          host: accept.host,
          protocolVersion: accept.protocolVersion,
          headersAll: accept.headersAll,
          contentLength: accept.contentLength,
          remote: accept.remote,
          local: accept.local,
          requestTransport: requestTransport,
          responseTransport: responseTransport,
        );
        if (_closed || _requests.isClosed) {
          await request.close();
          return;
        }
        _requests.add(request);
      } catch (error, stackTrace) {
        await requestTransport?.close();
        await responseTransport?.close();
        if (!_requests.isClosed) _requests.addError(error, stackTrace);
      }
    }());
  }

  void _closePendingAccepts() {
    for (final accept in _pendingAccepts) {
      accept.close();
    }
    _pendingAccepts.clear();
  }
}

final class _TailscaleHttpRequest implements TailscaleHttpRequest {
  _TailscaleHttpRequest({
    required this.method,
    required this.requestUri,
    required this.host,
    required this.protocolVersion,
    required Map<String, List<String>> headersAll,
    required this.contentLength,
    required this.remote,
    required this.local,
    required PosixFdTransport requestTransport,
    required PosixFdTransport responseTransport,
  }) : headersAll = Map.unmodifiable(headersAll),
       headers = Map.unmodifiable({
         for (final entry in headersAll.entries)
           if (entry.value.isNotEmpty) entry.key: entry.value.join(', '),
       }),
       uri = Uri.parse(requestUri.isEmpty ? '/' : requestUri),
       _requestTransport = requestTransport {
    response = _TailscaleHttpResponse(
      responseTransport,
      onClose: _closeRequestBody,
    );
    _body = StreamController<Uint8List>(
      onListen: () {
        _bodySub = _requestTransport.input.listen(
          _body.add,
          onError: (Object error, StackTrace stackTrace) {
            _body.addError(error, stackTrace);
            unawaited(_closeRequestBody());
          },
          onDone: () async {
            await _finishRequestBody();
          },
          cancelOnError: true,
        );
      },
      onPause: () => _bodySub?.pause(),
      onResume: () => _bodySub?.resume(),
      onCancel: () async {
        await _closeRequestBody();
      },
    );
  }

  final PosixFdTransport _requestTransport;
  late final StreamController<Uint8List> _body;
  @override
  late final TailscaleHttpResponse response;
  StreamSubscription<Uint8List>? _bodySub;
  Future<void>? _requestBodyClosed;

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final String requestUri;

  @override
  final String host;

  @override
  final String protocolVersion;

  @override
  final Map<String, String> headers;

  @override
  final Map<String, List<String>> headersAll;

  @override
  final int? contentLength;

  @override
  final TailscaleEndpoint local;

  @override
  final TailscaleEndpoint remote;

  @override
  Stream<Uint8List> get body => _body.stream;

  @override
  Future<void> respond({
    int statusCode = 200,
    Map<String, String>? headers,
    Object? body,
  }) async {
    response.statusCode = statusCode;
    if (headers != null) {
      for (final entry in headers.entries) {
        response.setHeader(entry.key, entry.value);
      }
    }

    switch (body) {
      case null:
        break;
      case String text:
        final encoded = utf8.encode(text);
        _putResponseHeaderIfAbsent(response, 'content-length', encoded.length);
        await response.write(encoded);
      case List<int> bytes:
        _putResponseHeaderIfAbsent(response, 'content-length', bytes.length);
        await response.write(bytes);
      case Stream<List<int>> chunks:
        await response.writeAll(chunks);
      default:
        final text = body.toString();
        final encoded = utf8.encode(text);
        _putResponseHeaderIfAbsent(response, 'content-length', encoded.length);
        await response.write(encoded);
    }

    await response.close();
  }

  Future<void> close() async {
    await Future.wait(<Future<void>>[response.close(), _closeRequestBody()]);
  }

  Future<void> _closeRequestBody() {
    final existing = _requestBodyClosed;
    if (existing != null) return existing;
    return _requestBodyClosed = () async {
      await _bodySub?.cancel();
      await _requestTransport.close();
      _closeBodyController();
    }();
  }

  Future<void> _finishRequestBody() {
    final existing = _requestBodyClosed;
    if (existing != null) return existing;
    return _requestBodyClosed = () async {
      await _requestTransport.close();
      _closeBodyController();
    }();
  }

  void _closeBodyController() {
    if (!_body.isClosed) unawaited(_body.close());
  }
}

final class _TailscaleHttpResponse implements TailscaleHttpResponse {
  _TailscaleHttpResponse(this._transport, {Future<void> Function()? onClose})
    : _onClose = onClose;

  final PosixFdTransport _transport;
  final Future<void> Function()? _onClose;
  final _headers = <String, String>{};
  final _extraHeaderValues = <String, List<String>>{};
  final _done = Completer<void>();
  var _statusCode = 200;
  var _headSent = false;
  var _closed = false;

  @override
  int get statusCode => _statusCode;

  @override
  set statusCode(int value) {
    if (_headSent) {
      throw StateError('HTTP response status cannot change after body write.');
    }
    if (value < 100 || value > 999) {
      throw ArgumentError.value(value, 'value', 'must be an HTTP status code');
    }
    _statusCode = value;
  }

  @override
  Map<String, String> get headers => _headers;

  @override
  Map<String, List<String>> get headersAll => _headerSnapshot();

  @override
  void setHeader(String name, String value) {
    _checkHeaderMutable();
    _headers[name] = value;
    _extraHeaderValues.remove(name);
  }

  @override
  void addHeader(String name, String value) {
    _checkHeaderMutable();
    if (!_headers.containsKey(name)) {
      _headers[name] = value;
      return;
    }
    (_extraHeaderValues[name] ??= <String>[]).add(value);
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) throw StateError('HTTP response is closed.');
    if (bytes.isEmpty) {
      await _sendHead();
      return;
    }
    await _sendHead();
    await _transport.write(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
  }

  @override
  Future<void> writeString(String text, {Encoding encoding = utf8}) =>
      write(encoding.encode(text));

  @override
  Future<void> writeAll(Stream<List<int>> chunks, {bool close = false}) async {
    await for (final chunk in chunks) {
      await write(chunk);
    }
    if (close) await this.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return done;
    _closed = true;
    try {
      await _sendHead();
      await _transport.closeWrite();
      await _transport.close();
      await _onClose?.call();
      if (!_done.isCompleted) _done.complete();
    } catch (error, stackTrace) {
      await _transport.close();
      await _onClose?.call();
      if (!_done.isCompleted) _done.completeError(error, stackTrace);
      rethrow;
    }
    return done;
  }

  Future<void> _sendHead() async {
    if (_headSent) return;
    _headSent = true;
    final payload = utf8.encode(
      jsonEncode({'statusCode': _statusCode, 'headers': _headerSnapshot()}),
    );
    if (payload.length > tailscaleMaxHttpHeadBytes) {
      throw StateError('HTTP response headers are too large.');
    }
    final bytes = Uint8List(4 + payload.length);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, payload.length, Endian.big);
    bytes.setRange(4, bytes.length, payload);
    await _transport.write(bytes);
  }

  void _checkHeaderMutable() {
    if (_headSent) {
      throw StateError('HTTP response headers cannot change after body write.');
    }
  }

  Map<String, List<String>> _headerSnapshot() {
    final snapshot = <String, List<String>>{
      for (final entry in _headers.entries) entry.key: <String>[entry.value],
    };
    for (final entry in _extraHeaderValues.entries) {
      (snapshot[entry.key] ??= <String>[]).addAll(entry.value);
    }
    return {
      for (final entry in snapshot.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    };
  }
}

final class _PendingHttpAccept {
  const _PendingHttpAccept({
    required this.requestBodyFd,
    required this.responseBodyFd,
    required this.method,
    required this.requestUri,
    required this.host,
    required this.protocolVersion,
    required this.headersAll,
    required this.contentLength,
    required this.remote,
    required this.local,
  });

  final int requestBodyFd;
  final int responseBodyFd;
  final String method;
  final String requestUri;
  final String host;
  final String protocolVersion;
  final Map<String, List<String>> headersAll;
  final int? contentLength;
  final TailscaleEndpoint remote;
  final TailscaleEndpoint local;

  void close() {
    closePosixFdForCleanup(requestBodyFd);
    closePosixFdForCleanup(responseBodyFd);
  }
}

void _putResponseHeaderIfAbsent(
  TailscaleHttpResponse response,
  String name,
  int value,
) {
  if (!_hasHeader(response.headers, name)) {
    response.setHeader(name, '$value');
  }
}

bool _hasHeader(Map<String, String> headers, String name) {
  for (final key in headers.keys) {
    if (key.toLowerCase() == name.toLowerCase()) return true;
  }
  return false;
}

void _httpAcceptLoop(List<Object> args) {
  final bindingId = args[0] as int;
  final sendPort = args[1] as SendPort;

  while (true) {
    final resultPtr = native.duneHttpAccept(bindingId);
    final resultJson = resultPtr.toDartString();
    native.duneFree(resultPtr);

    final result = jsonDecode(resultJson) as Map<String, dynamic>;
    if (result['closed'] == true) {
      sendPort.send(null);
      return;
    }
    final error = result['error'] as String?;
    if (error != null) {
      sendPort.send(<Object>['error', error]);
      return;
    }

    final requestBodyFd = result['requestBodyFd'] as int?;
    final responseBodyFd = result['responseBodyFd'] as int?;
    if (requestBodyFd == null ||
        requestBodyFd < 0 ||
        responseBodyFd == null ||
        responseBodyFd < 0) {
      sendPort.send(<Object>[
        'error',
        'native accept returned invalid HTTP fds',
      ]);
      return;
    }

    sendPort.send(<Object?>[
      'accepted',
      requestBodyFd,
      responseBodyFd,
      result['method'] as String? ?? 'GET',
      result['requestUri'] as String? ?? '/',
      result['host'] as String? ?? '',
      result['proto'] as String? ?? 'HTTP/1.1',
      result['headers'],
      result['contentLength'],
      result['remoteAddress'] as String? ?? '',
      result['remotePort'] as int? ?? 0,
      result['localAddress'] as String? ?? '',
      result['localPort'] as int? ?? 0,
      result['bindingId'] as int? ?? bindingId,
    ]);
  }
}

Map<String, List<String>> _copyHeadersAll(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (entry.key is String)
        entry.key as String: switch (entry.value) {
          final List<dynamic> values => [
            for (final value in values) value.toString(),
          ],
          final String value => [value],
          final Object value => [value.toString()],
          null => const <String>[],
        },
  };
}

int? _parseNullableContentLength(Object? raw) {
  if (raw is int && raw >= 0) return raw;
  return null;
}
