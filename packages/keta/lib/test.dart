/// In-process test harness: drive an [App] with no sockets, build a [Context]
/// for unit-testing a handler, and run an expectation in both failure shapes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart' show test;

import 'src/app.dart';
import 'src/context.dart';
import 'src/log.dart';
import 'src/response.dart';
import 'src/transport.dart';

/// Builds a [Context] for unit-testing a handler in isolation, without routing.
///
/// [rawBody], when given, is used as the request body verbatim (taking
/// precedence over [jsonBody]) so a malformed-JSON or over-limit body can be
/// exercised; [maxBodyBytes] sets the body-size ceiling.
Context<E> testContext<E>(
  E env, {
  String method = 'GET',
  String path = '/',
  Map<String, String> params = const {},
  Map<String, String> headers = const {},
  Object? jsonBody,
  List<int>? rawBody,
  int maxBodyBytes = 1 << 20,
}) {
  final baseLog = env is HasLog
      ? (env as HasLog).log
      : StdoutLog(flushInterval: Duration.zero);
  final ctx = RequestCtx<E>(
    env: env,
    method: method,
    uri: Uri.parse(path),
    route: path,
    headers: {for (final e in headers.entries) e.key.toLowerCase(): e.value},
    remoteAddress: 'test',
    params: params,
    orderedCaptures: params.values.toList(),
    log: baseLog.withFields({'reqId': 'test', 'route': path}),
    maxBodyBytes: maxBodyBytes,
    body: rawBody != null
        ? Stream.value(rawBody)
        : jsonBody == null
        ? const Stream.empty()
        : Stream.value(utf8.encode(jsonEncode(jsonBody))),
  );
  return Context<E>(ctx);
}

/// A socket-free client that runs the full pipeline — radix compilation,
/// matching, middleware, and handlers — against an in-memory request.
class TestClient<E> {
  TestClient(App<E> app, E env) : _router = app.compile(env);
  final Router<E> _router;

  Future<TestResponse> get(String path, {Map<String, String>? headers}) =>
      _send('GET', path, null, headers);

  Future<TestResponse> post(
    String path, {
    Object? json,
    Map<String, String>? headers,
  }) => _send('POST', path, json, headers);

  Future<TestResponse> put(
    String path, {
    Object? json,
    Map<String, String>? headers,
  }) => _send('PUT', path, json, headers);

  Future<TestResponse> delete(
    String path, {
    Object? json,
    Map<String, String>? headers,
  }) => _send('DELETE', path, json, headers);

  Future<TestResponse> patch(
    String path, {
    Object? json,
    Map<String, String>? headers,
  }) => _send('PATCH', path, json, headers);

  Future<TestResponse> options(String path, {Map<String, String>? headers}) =>
      _send('OPTIONS', path, null, headers);

  Future<TestResponse> head(String path, {Map<String, String>? headers}) =>
      _send('HEAD', path, null, headers);

  Future<TestResponse> _send(
    String method,
    String path,
    Object? json,
    Map<String, String>? headers,
  ) async {
    final request = _TestRequest(method, Uri.parse(path), {
      for (final e in (headers ?? const {}).entries)
        e.key.toLowerCase(): e.value,
    }, json == null ? const [] : utf8.encode(jsonEncode(json)));
    final response = await _router.dispatch(request);
    return TestResponse._from(response);
  }
}

/// The materialized result of a [TestClient] request.
class TestResponse {
  TestResponse._(this.status, this.headers, this._body);
  final int status;
  final Map<String, String> headers;
  final String _body;

  static Future<TestResponse> _from(Response response) async {
    final body = response.body;
    final text = switch (body) {
      String() => body,
      List<int>() => utf8.decode(body),
      Stream<List<int>>() => utf8.decode(
        await body.expand((chunk) => chunk).toList(),
      ),
      _ => '',
    };
    return TestResponse._(response.status, response.headers, text);
  }

  String text() => _body;

  Object? json() => _body.isEmpty ? null : jsonDecode(_body);
}

/// The two shapes a handler can fail in.
enum FailureMode {
  /// The handler throws synchronously.
  syncThrow,

  /// The handler returns a [Future] that rejects.
  asyncReject;

  /// Wraps [run] so the failure it raises is delivered in this mode's shape.
  FutureOr<Response> Function() wrap(FutureOr<Response> Function() run) =>
      this == syncThrow ? run : () => Future.sync(run);
}

/// Registers [body] as a test in both [FailureMode]s, so one expectation
/// exercises the synchronous-throw and rejected-Future paths alike.
void testBothModes(
  String description,
  FutureOr<void> Function(FailureMode mode) body,
) {
  for (final mode in FailureMode.values) {
    test('$description [${mode.name}]', () => body(mode));
  }
}

class _TestRequest implements TransportRequest {
  _TestRequest(this.method, this.uri, this.headers, this._body);
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, String> headers;
  final List<int> _body;

  @override
  Stream<List<int>> get bodyStream =>
      _body.isEmpty ? const Stream.empty() : Stream.value(_body);

  @override
  String get remoteAddress => 'test';

  // The in-process client never disconnects.
  @override
  Future<void> get closed => Completer<void>().future;
}
