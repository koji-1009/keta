library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'chain.dart';
import 'context.dart';
import 'h1_transport.dart';
import 'log.dart';
import 'response.dart';
import 'routing.dart';
import 'transport.dart';

/// A leaf request handler.
typedef Handler<E> = FutureOr<Response> Function(Context<E> c);

/// A middleware: it may run code around [next] and short-circuit by returning
/// its own response.
typedef Middleware<E> = FutureOr<Response> Function(
    Context<E> c, Handler<E> next);

/// A typed-DSL handler, receiving the path's captured tuple as [params].
typedef TypedHandler<E, T> = FutureOr<Response> Function(
    Context<E> c, T params);

/// One registered route, before the trie is compiled.
class _Reg<E> {
  final String method;
  final List<Segment> segments;
  final List<Capture<Object?>> captures;
  final List<String> captureNames;
  final Handler<E> handler;
  final List<Middleware<E>> groupMiddleware;
  final Object? doc;
  final String template;

  _Reg(this.method, this.segments, this.captures, this.captureNames,
      this.handler, this.groupMiddleware, this.doc, this.template);
}

/// A registered route exposed for OpenAPI generation and inspection.
class RouteEntry {
  final String method;
  final List<Segment> segments;
  final Object? doc;
  final String template;

  const RouteEntry(this.method, this.segments, this.doc, this.template);
}

/// The application: a routing table plus app-wide middleware.
///
/// Registration collects routes; [serve] compiles them into a radix trie and
/// fails fast on any conflict.
class App<E> {
  final List<Middleware<E>> _middleware = [];
  final List<_Reg<E>> _regs = [];

  /// Adds app-wide middleware. Runs before any group middleware, in the order
  /// added. Returns `this` for chaining with `..use(...)`.
  App<E> use(Middleware<E> m) {
    _middleware.add(m);
    return this;
  }

  /// A child router that prefixes [prefix] onto its routes and confines its own
  /// middleware to that subtree.
  RouteGroup<E> group(String prefix) =>
      RouteGroup<E>._(this, _prefixSegments(prefix), <Middleware<E>>[]);

  void get(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('GET', path, handler, doc, const [], const []);
  void post(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('POST', path, handler, doc, const [], const []);
  void put(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('PUT', path, handler, doc, const [], const []);
  void delete(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('DELETE', path, handler, doc, const [], const []);
  void patch(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('PATCH', path, handler, doc, const [], const []);
  void head(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('HEAD', path, handler, doc, const [], const []);
  void options(Object path, Handler<E> handler, {Object? doc}) =>
      _addPlain('OPTIONS', path, handler, doc, const [], const []);

  /// Opens the typed-DSL entry for [path]. Bind verbs on the returned [Route]
  /// with the same names as the string form: `app.on(path).post((c, p) => ...)`,
  /// where `p` is the path's captured tuple.
  Route<E, T> on<T>(Path<T> path) => Route<E, T>._(this, path, const [], const []);

  /// All registered routes, in registration order.
  List<RouteEntry> get routes => [
        for (final r in _regs)
          RouteEntry(r.method, r.segments, r.doc, r.template),
      ];

  void _addPlain(String method, Object path, Handler<E> handler, Object? doc,
      List<Segment> prefixSegments, List<Middleware<E>> groupMiddleware) {
    final base = _basePath(path);
    final segments = [...prefixSegments, ...base.segments];
    // Captures from the whole path — a captured group prefix must be readable
    // via c.param too.
    _register(method, segments, _capturesOf(segments), handler, doc,
        groupMiddleware);
  }

  void _addTyped<T>(String method, Path<T> path, TypedHandler<E, T> handler,
      Object? doc, List<Segment> prefixSegments,
      List<Middleware<E>> groupMiddleware) {
    final segments = [...prefixSegments, ...path.segments];
    // The tuple carries only the base path's captures; any group-prefix
    // captures precede them in match order, so the adapter reads the base
    // captures starting past the prefix ones.
    final prefixCaptureCount = prefixSegments.whereType<CaptureSegment>().length;
    _register(
      method,
      segments,
      _capturesOf(segments),
      _typedAdapter(path, path.captures.toList(), prefixCaptureCount, handler),
      doc,
      groupMiddleware,
    );
  }

  static List<Capture<Object?>> _capturesOf(List<Segment> segments) =>
      [for (final s in segments.whereType<CaptureSegment>()) s.capture];

  void _register(String method, List<Segment> segments,
      List<Capture<Object?>> captures, Handler<E> handler, Object? doc,
      List<Middleware<E>> groupMiddleware) {
    final names = [
      for (var i = 0; i < captures.length; i++) captures[i].name ?? 'p$i',
    ];
    // Duplicate capture names would make the first unreadable via c.param —
    // fail fast at registration.
    final seen = <String>{};
    for (final name in names) {
      if (!seen.add(name)) {
        throw StateError(
            'duplicate capture name ":$name" in ${templateOf(segments)}');
      }
    }
    _regs.add(_Reg<E>(
      method,
      segments,
      captures,
      names,
      handler,
      // Snapshot the group middleware at registration, so a later `..use()`
      // affects only subsequently-registered routes (order-deterministic).
      [...groupMiddleware],
      doc,
      templateOf(segments),
    ));
  }

  Path<dynamic> _basePath(Object path) => switch (path) {
        String() => parsePathString(path),
        Path() => path,
        _ => throw ArgumentError.value(
            path, 'path', 'must be a String or Path'),
      };

  /// Wraps a typed handler so it presents as a plain [Handler]: captures are
  /// parsed at the boundary (a [FormatException] becomes 400) and delivered as
  /// the path's typed tuple.
  Handler<E> _typedAdapter<T>(Path<T> path, List<Capture<Object?>> captures,
      int offset, TypedHandler<E, T> handler) {
    return (Context<E> c) {
      final raw = ctxOf(c).orderedCaptures;
      final parsed = List<Object?>.filled(captures.length, null);
      for (var i = 0; i < captures.length; i++) {
        try {
          parsed[i] = captures[i].parse(raw[offset + i]);
        } on FormatException {
          throw KetaException(400, 'invalid path parameter "${raw[offset + i]}"');
        }
      }
      return handler(c, path.buildTuple(parsed));
    };
  }

  /// Compiles the routing table into a dispatcher, failing fast on conflicts.
  /// Shared by [serve] and the test client so both enforce the same checks.
  ///
  /// [log] overrides the base logger; without it, the logger comes from a
  /// [HasLog] env, or a timer-free [StdoutLog] fallback (so a test client
  /// leaves no periodic timer pinning the isolate).
  Router<E> compile(E env, {int maxBodyBytes = 1 << 20, Log? log}) {
    final root = _TrieNode<E>();
    final seen = <String>{};
    for (final reg in _regs) {
      final key = conflictKey(reg.method, reg.segments);
      if (!seen.add(key)) {
        throw StateError(
            'route conflict: ${reg.method} ${reg.template} registered twice');
      }
      // Only group middleware wraps the leaf; app-level middleware wraps the
      // whole dispatch (below) so it also covers 404/405 — e.g. CORS preflight.
      _insert(root, reg, _compose(reg.groupMiddleware, reg.handler));
    }
    final baseLog = log ??
        (env is HasLog
            ? (env as HasLog).log
            : StdoutLog(flushInterval: Duration.zero));
    return Router<E>._(
        root, env, baseLog, maxBodyBytes, [..._middleware]);
  }

  /// Starts the server, booting one env per isolate, and returns a [Server]
  /// that shuts every isolate down gracefully.
  ///
  /// [boot] runs once on this isolate and once inside each of the
  /// [isolates] − 1 spawned isolates; every isolate owns and later closes its
  /// own env — the signature makes "boots N times" visible rather than passing
  /// one instance that cannot cross an isolate boundary. With [isolates] > 1,
  /// [boot] and this app's handlers must be sendable (top-level or static
  /// tear-offs, or closures over sendable state); a non-sendable one fails fast
  /// with a [StateError] when the isolate is spawned. A custom [transport] is
  /// only supported with a single isolate.
  Future<Server> serve(
    Future<E> Function() boot, {
    int port = 8080,
    int isolates = 1,
    Transport? transport,
    int maxBodyBytes = 1 << 20,
  }) async {
    if (isolates < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'must be >= 1');
    }
    if (isolates > 1 && transport != null) {
      throw ArgumentError.value(
          transport, 'transport', 'not supported with isolates > 1');
    }
    // Worker 0 runs on the current isolate; bind it first so a configuration
    // error surfaces here before any child is spawned.
    final env = await boot();
    // A running server flushes periodically; only the env-less fallback needs a
    // timer here (a HasLog env owns its own).
    final fallbackLog = env is HasLog ? null : StdoutLog();
    final router = compile(env, maxBodyBytes: maxBodyBytes, log: fallbackLog);
    final t = transport ??
        H1Transport(
            onError: (e, st) => router.baseLog.error('transport error', e, st));
    final server = await t.bind(port, router.dispatch);
    if (isolates == 1) {
      return _Server<E>(env, router.baseLog, server);
    }
    final workers = <_Worker>[];
    for (var i = 1; i < isolates; i++) {
      workers.add(await _spawnWorker<E>(this, boot, port, maxBodyBytes));
    }
    return _MultiServer<E>(env, router.baseLog, server, workers);
  }

  void _insert(_TrieNode<E> root, _Reg<E> reg, Handler<E> composed) {
    var node = root;
    for (final seg in reg.segments) {
      node = switch (seg) {
        LiteralSegment(:final value) =>
          node.literals.putIfAbsent(value, _TrieNode<E>.new),
        CaptureSegment() => node.capture ??= _TrieNode<E>(),
      };
    }
    node.methods[reg.method] =
        _Compiled<E>(composed, reg.captureNames, reg.template);
  }

  Handler<E> _compose(List<Middleware<E>> middleware, Handler<E> base) {
    var handler = base;
    for (final m in middleware.reversed) {
      final next = handler;
      handler = (c) => m(c, next);
    }
    return handler;
  }
}

List<Segment> _prefixSegments(String prefix) =>
    parsePathString(prefix).segments;

/// A prefixed child router with its own confined middleware.
class RouteGroup<E> {
  final App<E> _app;
  final List<Segment> _prefix;
  final List<Middleware<E>> _middleware;

  RouteGroup._(this._app, this._prefix, this._middleware);

  /// Adds middleware confined to this group's routes. Runs after app-wide
  /// middleware, in the order added.
  RouteGroup<E> use(Middleware<E> m) {
    _middleware.add(m);
    return this;
  }

  void get(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('GET', path, handler, doc, _prefix, _middleware);
  void post(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('POST', path, handler, doc, _prefix, _middleware);
  void put(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('PUT', path, handler, doc, _prefix, _middleware);
  void delete(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('DELETE', path, handler, doc, _prefix, _middleware);
  void patch(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('PATCH', path, handler, doc, _prefix, _middleware);
  void head(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('HEAD', path, handler, doc, _prefix, _middleware);
  void options(Object path, Handler<E> handler, {Object? doc}) =>
      _app._addPlain('OPTIONS', path, handler, doc, _prefix, _middleware);

  /// Opens the typed-DSL entry for [path] within this group, carrying the
  /// group's prefix and middleware.
  Route<E, T> on<T>(Path<T> path) =>
      Route<E, T>._(_app, path, _prefix, _middleware);
}

/// The typed-DSL binding surface for one [Path]. Its verbs mirror [App]'s but
/// hand the handler the path's captured tuple.
class Route<E, T> {
  final App<E> _app;
  final Path<T> _path;
  final List<Segment> _prefix;
  final List<Middleware<E>> _middleware;

  Route._(this._app, this._path, this._prefix, this._middleware);

  void get(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('GET', _path, handler, doc, _prefix, _middleware);
  void post(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('POST', _path, handler, doc, _prefix, _middleware);
  void put(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('PUT', _path, handler, doc, _prefix, _middleware);
  void delete(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('DELETE', _path, handler, doc, _prefix, _middleware);
  void patch(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('PATCH', _path, handler, doc, _prefix, _middleware);
  void head(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('HEAD', _path, handler, doc, _prefix, _middleware);
  void options(TypedHandler<E, T> handler, {Object? doc}) =>
      _app._addTyped('OPTIONS', _path, handler, doc, _prefix, _middleware);
}

class _TrieNode<E> {
  final Map<String, _TrieNode<E>> literals = {};
  _TrieNode<E>? capture;
  final Map<String, _Compiled<E>> methods = {};
}

class _Compiled<E> {
  final Handler<E> handler;
  final List<String> captureNames;
  final String template;

  _Compiled(this.handler, this.captureNames, this.template);
}

/// The compiled dispatcher: a radix trie plus the bound env. Matching stays on
/// the synchronous path so a sync handler allocates no [Future].
class Router<E> {
  final _TrieNode<E> _root;
  final E env;
  final Log baseLog;
  final int maxBodyBytes;
  final Random _random = Random.secure();

  /// App-level middleware composed around the whole dispatch, including the
  /// 404/405 synthesis, so a cross-cutting concern (CORS preflight, access log)
  /// covers unmatched requests too.
  late final Handler<E> _appHandler;

  Router._(this._root, this.env, this.baseLog, this.maxBodyBytes,
      List<Middleware<E>> appMiddleware) {
    var handler = _terminal;
    for (final m in appMiddleware.reversed) {
      final next = handler;
      handler = (c) => m(c, next);
    }
    _appHandler = handler;
  }

  FutureOr<Response> dispatch(TransportRequest request) {
    final segments = _decodedSegments(request.uri);
    final captured = <String>[];
    final (compiled, pathMatched) =
        _walk(_root, segments, 0, request.method, captured);
    final reqId = _reqId();
    final route = compiled?.template ?? request.uri.path;
    final params = <String, String>{
      if (compiled != null)
        for (var i = 0; i < compiled.captureNames.length; i++)
          compiled.captureNames[i]: captured[i],
    };
    final ctx = RequestCtx<E>(
      env: env,
      method: request.method,
      uri: request.uri,
      route: route,
      headers: request.headers,
      remoteAddress: request.remoteAddress,
      params: params,
      orderedCaptures: captured,
      log: baseLog.withFields({'reqId': reqId, 'route': route}),
      maxBodyBytes: maxBodyBytes,
      body: request.bodyStream,
    )
      ..matched = compiled?.handler
      ..pathMatched = pathMatched;
    final c = Context<E>(ctx);
    return guard(() => _appHandler(c), (e, st) => _fallback(e, st, ctx));
  }

  /// The innermost handler: the matched route, or the 404/405 response.
  FutureOr<Response> _terminal(Context<E> c) {
    final handler = ctxOf(c).matched;
    if (handler != null) return handler(c);
    final pathMatched = ctxOf(c).pathMatched;
    return Response.json(
      {'error': pathMatched ? 'method not allowed' : 'not found'},
      pathMatched ? 405 : 404,
    );
  }

  /// The last-resort fallback, always applied: `KetaException` maps to its
  /// status with a JSON error body, anything else to 500 with the error logged
  /// and no detail leaked.
  Response _fallback(Object error, StackTrace st, RequestCtx<E> ctx) {
    if (error is KetaException) {
      return Response.json({'error': error.message}, error.status);
    }
    ctx.log.error('unhandled exception', error, st);
    return Response(500, body: '');
  }

  String _reqId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Depth-first match, literal before capture, with backtracking so a failed
/// literal branch still lets a capture branch match. Returns the compiled route
/// (or null) and whether any route shares this path (to distinguish 405 from
/// 404).
(_Compiled<E>?, bool) _walk<E>(_TrieNode<E> node, List<String> segments,
    int i, String method, List<String> captured) {
  if (i == segments.length) {
    return (node.methods[method], node.methods.isNotEmpty);
  }
  final seg = segments[i];
  var pathMatched = false;
  final literal = node.literals[seg];
  if (literal != null) {
    final (route, matched) = _walk(literal, segments, i + 1, method, captured);
    if (route != null) return (route, true);
    pathMatched = pathMatched || matched;
  }
  final capture = node.capture;
  if (capture != null) {
    captured.add(seg);
    final (route, matched) = _walk(capture, segments, i + 1, method, captured);
    if (route != null) return (route, true);
    captured.removeLast();
    pathMatched = pathMatched || matched;
  }
  return (null, pathMatched);
}

/// Matchable path segments, percent-decoded, with empty segments dropped so a
/// trailing slash and interior `//` stay tolerant. `uri.pathSegments` decodes
/// each segment and keeps `%2F` inside a single segment.
List<String> _decodedSegments(Uri uri) =>
    [for (final s in uri.pathSegments) if (s.isNotEmpty) s];

/// A running server.
abstract interface class Server {
  /// Stops accepting requests, waits out in-flight work up to [grace], closes
  /// the env, and flushes logs.
  Future<void> shutdown({Duration grace});
}

class _Server<E> implements Server {
  final E env;
  final Log _baseLog;
  final TransportServer _transport;

  _Server(this.env, this._baseLog, this._transport);

  @override
  Future<void> shutdown(
      {Duration grace = const Duration(seconds: 30)}) async {
    await _transport.close(grace: grace);
    if (env is Disposable) await (env as Disposable).close();
    await _baseLog.flush();
    if (_baseLog is StdoutLog) _baseLog.dispose();
  }
}

/// A handle to a spawned worker isolate and its shutdown control port.
class _Worker {
  final Isolate isolate;
  final SendPort control;

  _Worker(this.isolate, this.control);
}

/// The server for [App.serve] with `isolates > 1`: worker 0 runs here, the rest
/// in spawned isolates driven over control ports.
class _MultiServer<E> implements Server {
  final E _env;
  final Log _baseLog;
  final TransportServer _transport;
  final List<_Worker> _workers;

  _MultiServer(this._env, this._baseLog, this._transport, this._workers);

  @override
  Future<void> shutdown({Duration grace = const Duration(seconds: 30)}) async {
    final ports = <ReceivePort>[];
    final acks = <Future<void>>[];
    for (final worker in _workers) {
      final ack = ReceivePort();
      ports.add(ack);
      worker.control.send((ack.sendPort, grace.inMilliseconds));
      acks.add(ack.first.then((_) {}));
    }
    await _transport.close(grace: grace);
    if (_env is Disposable) await (_env as Disposable).close();
    await _baseLog.flush();
    if (_baseLog is StdoutLog) _baseLog.dispose();
    await Future.wait(acks)
        .timeout(grace + const Duration(seconds: 5), onTimeout: () => const []);
    // Close every ack port whether or not the ack arrived — an un-closed
    // ReceivePort keeps this isolate alive and hangs the process.
    for (final port in ports) {
      port.close();
    }
    for (final worker in _workers) {
      worker.isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<_Worker> _spawnWorker<E>(
    App<E> app, Future<E> Function() boot, int port, int maxBodyBytes) async {
  final ready = ReceivePort();
  final errors = ReceivePort();
  try {
    final isolate = await Isolate.spawn(
      _workerEntry<E>,
      (app, boot, port, maxBodyBytes, ready.sendPort),
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
    // Whichever comes first: the child's control port (bound) or an error.
    final control = await Future.any([
      ready.first,
      errors.first.then<Object?>(
          (e) => throw StateError('worker failed to start: $e')),
    ]);
    return _Worker(isolate, control as SendPort);
  } on ArgumentError catch (e) {
    throw StateError(
        'serve(isolates > 1) requires a sendable boot and handlers: $e');
  } finally {
    ready.close();
    errors.close();
  }
}

Future<void> _workerEntry<E>(
    (App<E>, Future<E> Function(), int, int, SendPort) args) async {
  final (app, boot, port, maxBodyBytes, ready) = args;
  final env = await boot();
  final fallbackLog = env is HasLog ? null : StdoutLog();
  final router = app.compile(env, maxBodyBytes: maxBodyBytes, log: fallbackLog);
  final transport = await H1Transport(
          onError: (e, st) => router.baseLog.error('transport error', e, st))
      .bind(port, router.dispatch);

  final control = ReceivePort();
  ready.send(control.sendPort);
  final (SendPort ack, int graceMs) = await control.first as (SendPort, int);
  await transport.close(grace: Duration(milliseconds: graceMs));
  if (env is Disposable) await (env as Disposable).close();
  await router.baseLog.flush();
  if (router.baseLog is StdoutLog) (router.baseLog as StdoutLog).dispose();
  control.close();
  ack.send(null);
}

/// An environment that exposes a [Log]. When `E` implements this, per-request
/// logging (`c.log`) and access logs flow through it; otherwise the framework
/// falls back to a default [StdoutLog].
abstract interface class HasLog {
  Log get log;
}

/// An environment with resources to release on shutdown. When `E` implements
/// this, [Server.shutdown] calls [close] after draining in-flight requests.
abstract interface class Disposable {
  Future<void> close();
}
