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
import 'src/upgrade.dart';

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
  final ctx =
      RequestCtx<E>(
          env: env,
          method: method,
          uri: Uri.parse(path),
          headers: {
            for (final e in headers.entries) e.key.toLowerCase(): [e.value],
          },
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
        )
        // Testing a handler directly (no routing occurs), so `path` stands in
        // as the matched template — the same bounded value a real dispatch
        // would have baked into the log line.
        ..matchedTemplate = path;
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

  /// Attempts a WebSocket upgrade against [path], running the FULL pipeline —
  /// matching, app/group middleware, the security gate, `recover` — before the
  /// upgrade decision, exactly as a real transport would. This is the payoff of
  /// modelling the upgrade as a returned value: the test harness is just another
  /// actor that reads `Response.upgrade`, so a socket-free upgrade falls out
  /// naturally instead of being a special case bolted on.
  ///
  /// Returns a [TestUpgrade]: when the route upgraded, a connected in-process
  /// [TestSocket] whose messages round-trip through the handler's channel;
  /// otherwise the ordinary [TestResponse] the pipeline produced instead (a 401
  /// from the security gate, a 404, a 405). The connection callback is driven
  /// on an in-memory channel pair, so message ordering and close semantics match
  /// a real socket without opening one.
  Future<TestUpgrade> connect(
    String path, {
    Map<String, String>? headers,
  }) async {
    final request = _TestRequest('GET', Uri.parse(path), {
      // Present so the in-process request resembles a real handshake; the core
      // does not inspect them (only a real transport does), and a caller may
      // override them.
      'connection': const ['Upgrade'],
      'upgrade': const ['websocket'],
      for (final e in (headers ?? const {}).entries)
        e.key.toLowerCase(): [e.value],
    }, const []);
    final response = await _router.dispatch(request);
    final upgrade = response.upgrade;
    if (upgrade == null) {
      return TestUpgrade._(null, await TestResponse._from(response));
    }
    final link = _InProcessLink();
    // Drive the handler's callback on the server side of the pair. A throw from
    // it closes the link so the client's `done` still completes — an in-process
    // mirror of the transport closing a socket whose handler blew up.
    unawaited(
      Future.sync(
        () => realizeUpgrade(upgrade, _ServerChannel(link)),
      ).then((_) {}, onError: (Object _) => link._close()),
    );
    return TestUpgrade._(TestSocket._(link), null);
  }

  Future<TestResponse> _send(
    String method,
    String path,
    Object? json,
    Map<String, String>? headers,
  ) async {
    final request = _TestRequest(method, Uri.parse(path), {
      for (final e in (headers ?? const {}).entries)
        e.key.toLowerCase(): [e.value],
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
    return TestResponse._(response.status, {
      // Flattened to first value for assertion convenience; multi-value fidelity
      // is exercised at the Response/bridge level.
      for (final e in response.headers.entries)
        e.key: e.value.isEmpty ? '' : e.value.first,
    }, text);
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
  final Map<String, List<String>> headers;
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

/// The outcome of [TestClient.connect]: either an upgraded [socket] or the
/// [rejection] response the pipeline returned in its place. Exactly one is
/// non-null.
class TestUpgrade {
  TestUpgrade._(this.socket, this.rejection);

  /// The connected in-process socket when the route upgraded, else null.
  final TestSocket? socket;

  /// The ordinary response when the pipeline answered instead of upgrading
  /// (e.g. a 401 from the security gate), else null.
  final TestResponse? rejection;

  /// Whether the connection upgraded.
  bool get upgraded => socket != null;
}

/// The client end of an in-process upgraded connection, mirroring an
/// [UpgradedChannel] from the test's side: send messages to the handler, read
/// what it sends back, close, and observe closure — all without a socket.
class TestSocket {
  TestSocket._(this._link);
  final _InProcessLink _link;

  /// Messages the handler sent, in order (a `String` text or `List<int>` binary
  /// frame).
  Stream<Object> get messages => _link.toClient.stream;

  /// Sends [message] to the handler's channel. A send after [close] throws, as
  /// it would on a real socket.
  void send(Object message) => _link.toServer.add(message);

  /// Closes the connection from the client side; the handler's channel sees its
  /// `messages` end and its `done` complete.
  Future<void> close([int? code, String? reason]) async => _link._close();

  /// Completes when the connection closes, from either end.
  Future<void> get done => _link.clientDone.future;
}

/// The shared state behind an in-process upgraded connection: two directed
/// message streams and a symmetric close. Closing either end ends both streams
/// and completes both `done`s once — the ordering and finality a real socket
/// gives, reproduced in memory so upgrade handlers are testable without sockets.
class _InProcessLink {
  final StreamController<Object> toServer =
      StreamController<Object>(); // client→server
  final StreamController<Object> toClient =
      StreamController<Object>(); // server→client
  final Completer<void> serverDone = Completer<void>();
  final Completer<void> clientDone = Completer<void>();
  bool closed = false;

  void _close() {
    if (closed) return;
    closed = true;
    if (!serverDone.isCompleted) serverDone.complete();
    if (!clientDone.isCompleted) clientDone.complete();
    // Closing the sinks ends both `await for` loops and both message streams.
    unawaited(toServer.close());
    unawaited(toClient.close());
  }
}

/// The server (handler) end of an in-process upgraded connection — the
/// [UpgradedChannel] the handler's `onConnected` receives from [TestClient].
class _ServerChannel implements UpgradedChannel {
  _ServerChannel(this._link);
  final _InProcessLink _link;

  @override
  Stream<Object> get messages => _link.toServer.stream;

  @override
  void send(Object message) => _link.toClient.add(message);

  @override
  Future<void> close([int? code, String? reason]) async => _link._close();

  @override
  Future<void> get done => _link.serverDone.future;
}
