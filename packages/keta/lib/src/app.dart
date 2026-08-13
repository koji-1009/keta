library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'chain.dart';
import 'context.dart';
import 'h1_transport.dart';
import 'log.dart';
import 'order.dart';
import 'response.dart';
import 'route_doc.dart';
import 'routing.dart';
import 'transport.dart';

/// A leaf request handler.
typedef Handler<E> = FutureOr<Response> Function(Context<E> c);

/// A middleware: it may run code around [next] and short-circuit by returning
/// its own response.
typedef Middleware<E> = FutureOr<Response> Function(
  Context<E> c,
  Handler<E> next,
);

/// A typed-DSL handler, receiving the path's captured tuple as [params].
typedef TypedHandler<E, T> = FutureOr<Response> Function(
  Context<E> c,
  T params,
);

/// A registered middleware paired with the position it declared, so the chain
/// can be checked before it is composed. Null [order] is unconstrained.
class _Ordered<E>(final Middleware<E> middleware, final MiddlewareOrder? order);

/// One registered route, before the trie is compiled.
class _Reg<E>(
  final String method,
  final List<Segment> segments,
  final List<Capture<Object?>> captures,
  final List<String> captureNames,
  final Handler<E> handler,
  final List<_Ordered<E>> groupMiddleware,
  final RouteDoc? doc,
  final String template,
);

/// A registered route exposed for OpenAPI generation and inspection.
class const RouteEntry(
  final String method,
  final List<Segment> segments,
  final RouteDoc? doc,
  final String template,
);

/// The application: a routing table plus app-wide middleware.
///
/// Registration collects routes; [serve] compiles them into a radix trie and
/// fails fast on any conflict.
class App<E> {
  final List<_Ordered<E>> _middleware = [];
  final List<_Reg<E>> _regs = [];

  /// Adds app-wide middleware. Runs before any group middleware, in the order
  /// added. Returns `this` for chaining with `..use(...)`.
  ///
  /// [order] places [m] in the chain explicitly, overriding whatever position
  /// the middleware was tagged with at its definition site (keta's own carry
  /// one; see [KetaOrder]). Omit it and the tag stands — or, for a middleware
  /// that has none, the registration is unconstrained. [compile] rejects a
  /// chain whose positions do not ascend outward-to-inward.
  App<E> use(Middleware<E> m, {MiddlewareOrder? order}) {
    _middleware.add(_Ordered(m, order ?? orderOf(m)));
    return this;
  }

  /// A child router that prefixes [prefix] onto its routes and confines its own
  /// middleware to that subtree.
  RouteGroup<E> group(String prefix) =>
      RouteGroup<E>._(this, _prefixSegments(prefix), <_Ordered<E>>[]);

  void get(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('GET', path, handler, doc, const [], const []);
  void post(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('POST', path, handler, doc, const [], const []);
  void put(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('PUT', path, handler, doc, const [], const []);
  void delete(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('DELETE', path, handler, doc, const [], const []);
  void patch(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('PATCH', path, handler, doc, const [], const []);
  void head(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('HEAD', path, handler, doc, const [], const []);
  void options(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _addPlain('OPTIONS', path, handler, doc, const [], const []);

  /// Opens the typed-DSL entry for [path]. Bind verbs on the returned [Route]
  /// with the same names as the string form: `app.on(path).post((c, p) => ...)`,
  /// where `p` is the path's captured tuple.
  Route<E, T> on<T>(Path<T> path) =>
      Route<E, T>._(this, path, const [], const []);

  /// All registered routes, in registration order.
  List<RouteEntry> get routes => [
    for (final r in _regs) RouteEntry(r.method, r.segments, r.doc, r.template),
  ];

  void _addPlain(
    String method,
    Object path,
    Handler<E> handler,
    RouteDoc? doc,
    List<Segment> prefixSegments,
    List<_Ordered<E>> groupMiddleware,
  ) {
    final base = _basePath(path);
    final segments = [...prefixSegments, ...base.parts];
    // Captures from the whole path — a captured group prefix must be readable
    // via c.param too.
    _register(
      method,
      segments,
      _capturesOf(segments),
      handler,
      doc,
      groupMiddleware,
    );
  }

  void _addTyped<T>(
    String method,
    Path<T> path,
    TypedHandler<E, T> handler,
    RouteDoc? doc,
    List<Segment> prefixSegments,
    List<_Ordered<E>> groupMiddleware,
  ) {
    final segments = [...prefixSegments, ...path.parts];
    // The tuple carries only the base path's captures; any group-prefix
    // captures precede them in match order, so the adapter reads the base
    // captures starting past the prefix ones.
    final prefixCaptureCount = prefixSegments
        .whereType<CaptureSegment>()
        .length;
    _register(
      method,
      segments,
      _capturesOf(segments),
      _typedAdapter(path, path.captures.toList(), prefixCaptureCount, handler),
      doc,
      groupMiddleware,
    );
  }

  static List<Capture<Object?>> _capturesOf(List<Segment> segments) => [
    for (final s in segments.whereType<CaptureSegment>()) s.capture,
  ];

  void _register(
    String method,
    List<Segment> segments,
    List<Capture<Object?>> captures,
    Handler<E> handler,
    RouteDoc? doc,
    List<_Ordered<E>> groupMiddleware,
  ) {
    final names = [
      for (var i = 0; i < captures.length; i++) captures[i].name ?? 'p$i',
    ];
    // Duplicate capture names would make the first unreadable via c.param —
    // fail fast at registration.
    final seen = <String>{};
    for (final name in names) {
      if (!seen.add(name)) {
        throw StateError(
          'duplicate capture name ":$name" in ${templateOf(segments)}',
        );
      }
    }
    _regs.add(
      _Reg<E>(
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
      ),
    );
  }

  Path<dynamic> _basePath(Object path) => switch (path) {
    String() => parsePathString(path),
    Path() => path,
    // A shape that is data rather than written out — what a file tree denotes.
    // Reachable only here, never from `on()`, so it can never be asked for the
    // tuple it does not have.
    List<Segment>() => pathOfSegments(path),
    _ => throw ArgumentError.value(
      path,
      'path',
      'must be a String, a Path, or a List<Segment>',
    ),
  };

  /// Wraps a typed handler so it presents as a plain [Handler]: each capture
  /// parses at the boundary (its contract turns invalid input into a
  /// [BadRequest]; any other exception is a defect → 500) and the values are
  /// delivered as the path's typed tuple.
  Handler<E> _typedAdapter<T>(
    Path<T> path,
    List<Capture<Object?>> captures,
    int offset,
    TypedHandler<E, T> handler,
  ) {
    return (Context<E> c) {
      final raw = ctxOf(c).orderedCaptures;
      final parsed = List<Object?>.filled(captures.length, null);
      for (var i = 0; i < captures.length; i++) {
        parsed[i] = captures[i].parse(raw[offset + i]);
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
    // The chain a request actually runs, checked before it is composed. An
    // app with no routes still has an app-wide chain worth checking.
    final appOrders = [for (final m in _middleware) m.order];
    checkMiddlewareOrder(appOrders, 'app-wide middleware');
    for (final reg in _regs) {
      final key = conflictKey(reg.method, reg.segments);
      if (!seen.add(key)) {
        throw StateError(
          'route conflict: ${reg.method} ${reg.template} registered twice',
        );
      }
      // App-wide middleware always wraps a group's, so a route's chain is the
      // two sequences end to end — a group middleware placed further out than
      // an app-wide one is a violation the group's own list cannot show.
      checkMiddlewareOrder([
        ...appOrders,
        for (final m in reg.groupMiddleware) m.order,
      ], '${reg.method} ${reg.template}');
      // Only group middleware wraps the leaf; app-level middleware wraps the
      // whole dispatch (below) so it also covers 404/405 — e.g. CORS preflight.
      _insert(root, reg, _compose(reg.groupMiddleware, reg.handler));
    }
    final baseLog =
        log ??
        (env is HasLog
            ? (env as HasLog).log
            : StdoutLog(flushInterval: Duration.zero));
    return Router<E>._(root, env, baseLog, maxBodyBytes, [
      for (final m in _middleware) m.middleware,
    ]);
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
  /// with a [StateError] when the isolate is spawned.
  ///
  /// A transport can be supplied two ways, and which one is right follows the
  /// same rule as [boot]. [transport] hands over one already-built instance and
  /// is therefore single-isolate only — an instance cannot cross an isolate
  /// boundary. [transportFactory] is a sendable builder invoked once per
  /// isolate, so each worker constructs its own; it is how a configured
  /// transport reaches `serve(isolates: n)` at all.
  ///
  /// A factory is therefore the only way TLS and `idleTimeout` reach a
  /// multi-isolate server:
  ///
  /// ```dart
  /// Transport tls() => H1Transport(
  ///   securityContext: SecurityContext()
  ///     ..useCertificateChain('cert.pem')
  ///     ..usePrivateKey('key.pem'),
  ///   idleTimeout: const Duration(seconds: 10),
  /// );
  ///
  /// await app.serve(boot, isolates: 4, transportFactory: tls);
  /// ```
  ///
  /// Passing both is an authoring defect and throws.
  Future<Server> serve(
    Future<E> Function() boot, {
    int port = 8080,
    int isolates = 1,
    Transport? transport,
    Transport Function()? transportFactory,
    int maxBodyBytes = 1 << 20,
  }) async {
    if (isolates < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'must be >= 1');
    }
    if (transport != null && transportFactory != null) {
      throw ArgumentError(
        'pass either transport (one instance, single isolate) or '
        'transportFactory (built per isolate), not both',
      );
    }
    if (isolates > 1 && transport != null) {
      throw ArgumentError.value(
        transport,
        'transport',
        'not supported with isolates > 1 — an instance cannot cross an isolate '
            'boundary; pass transportFactory instead',
      );
    }
    // Worker 0 runs on the current isolate; bind it first so a configuration
    // error surfaces here before any child is spawned.
    final env = await boot();
    // A running server flushes periodically; only the env-less fallback needs a
    // timer here (a HasLog env owns its own).
    final fallbackLog = env is HasLog ? null : StdoutLog();
    // Named before `compile`, because everything between here and a bound
    // socket can throw and the teardown below needs something to flush.
    final bootLog = fallbackLog ?? (env as HasLog).log;
    final Router<E> router;
    final TransportServer server;
    try {
      // Both fail on ordinary misconfiguration — `compile` on a route conflict
      // or a middleware-order violation, `bind` on a port already in use — so
      // the teardown below is load-bearing: without it the env stays open and
      // `fallbackLog`'s periodic timer pins the isolate, and a process that
      // caught the error to exit cleanly hangs instead.
      router = compile(env, maxBodyBytes: maxBodyBytes, log: fallbackLog);
      final t =
          transport ??
          transportFactory?.call() ??
          H1Transport(
            onError: (e, st) => router.baseLog.error('transport error', e, st),
          );
      server = await t.bind(port, router.dispatch);
    } catch (_) {
      await _teardown(env, bootLog);
      rethrow;
    }
    if (isolates == 1) {
      return _Server<E>(env, router.baseLog, server);
    }
    final workers = <_Worker>[];
    try {
      for (var i = 1; i < isolates; i++) {
        workers.add(
          await _spawnWorker<E>(
            this,
            boot,
            port,
            maxBodyBytes,
            router.baseLog,
            transportFactory,
          ),
        );
      }
    } catch (_) {
      // Partial startup: worker 0 already bound its socket and booted its env.
      // Tear both down (and kill any workers that did spawn) before rethrowing,
      // so a failed spawn never leaks a live listener and an un-closed env with
      // no Server handle to release them.
      for (final worker in workers) {
        worker.kill();
      }
      await server.close(grace: Duration.zero);
      await _teardown(env, router.baseLog);
      rethrow;
    }
    return _MultiServer<E>(env, router.baseLog, server, workers);
  }

  void _insert(_TrieNode<E> root, _Reg<E> reg, Handler<E> composed) {
    var node = root;
    for (final seg in reg.segments) {
      node = switch (seg) {
        LiteralSegment(:final value) => node.literals.putIfAbsent(
          value,
          _TrieNode<E>.new,
        ),
        CaptureSegment() => node.capture ??= _TrieNode<E>(),
      };
    }
    node.methods[reg.method] = _Compiled<E>(
      composed,
      reg.captureNames,
      reg.template,
      reg.doc,
    );
  }

  Handler<E> _compose(List<_Ordered<E>> middleware, Handler<E> base) {
    var handler = base;
    for (final entry in middleware.reversed) {
      final next = handler;
      final m = entry.middleware;
      handler = (c) => m(c, next);
    }
    return handler;
  }
}

List<Segment> _prefixSegments(String prefix) => parsePathString(prefix).parts;

/// A prefixed child router with its own confined middleware.
class RouteGroup<E>._(
  final App<E> _app,
  final List<Segment> _prefix,
  final List<_Ordered<E>> _middleware,
) {
  /// Adds middleware confined to this group's routes. Runs after app-wide
  /// middleware, in the order added.
  ///
  /// [order] behaves exactly as on [App.use]. A route's chain is checked as one
  /// sequence — app-wide first, then this group's — because app-wide middleware
  /// always wraps a group's.
  RouteGroup<E> use(Middleware<E> m, {MiddlewareOrder? order}) {
    _middleware.add(_Ordered(m, order ?? orderOf(m)));
    return this;
  }

  void get(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('GET', path, handler, doc, _prefix, _middleware);
  void post(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('POST', path, handler, doc, _prefix, _middleware);
  void put(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('PUT', path, handler, doc, _prefix, _middleware);
  void delete(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('DELETE', path, handler, doc, _prefix, _middleware);
  void patch(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('PATCH', path, handler, doc, _prefix, _middleware);
  void head(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('HEAD', path, handler, doc, _prefix, _middleware);
  void options(Object path, Handler<E> handler, {RouteDoc? doc}) =>
      _app._addPlain('OPTIONS', path, handler, doc, _prefix, _middleware);

  /// Opens the typed-DSL entry for [path] within this group, carrying the
  /// group's prefix and middleware.
  Route<E, T> on<T>(Path<T> path) =>
      Route<E, T>._(_app, path, _prefix, _middleware);
}

/// The typed-DSL binding surface for one [Path]. Its verbs mirror [App]'s but
/// hand the handler the path's captured tuple.
class Route<E, T>._(
  final App<E> _app,
  final Path<T> _path,
  final List<Segment> _prefix,
  final List<_Ordered<E>> _middleware,
) {
  void get(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('GET', _path, handler, doc, _prefix, _middleware);
  void post(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('POST', _path, handler, doc, _prefix, _middleware);
  void put(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('PUT', _path, handler, doc, _prefix, _middleware);
  void delete(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('DELETE', _path, handler, doc, _prefix, _middleware);
  void patch(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('PATCH', _path, handler, doc, _prefix, _middleware);
  void head(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('HEAD', _path, handler, doc, _prefix, _middleware);
  void options(TypedHandler<E, T> handler, {RouteDoc? doc}) =>
      _app._addTyped('OPTIONS', _path, handler, doc, _prefix, _middleware);
}

class _TrieNode<E> {
  final Map<String, _TrieNode<E>> literals = {};
  _TrieNode<E>? capture;
  final Map<String, _Compiled<E>> methods = {};
}

class _Compiled<E>(
  final Handler<E> handler,
  final List<String> captureNames,
  final String template,
  final RouteDoc? doc,
);

/// The compiled dispatcher: a radix trie plus the bound env. Matching stays on
/// the synchronous path so a sync handler allocates no [Future].
class Router<E>._(
  final _TrieNode<E> _root,
  final E env,
  final Log baseLog,
  final int maxBodyBytes,
  List<Middleware<E>> appMiddleware,
) {
  this {
    var handler = _terminal;
    for (final m in appMiddleware.reversed) {
      final next = handler;
      handler = (c) => m(c, next);
    }
    _appHandler = handler;
  }
  final Random _random = Random.secure();

  /// App-level middleware composed around the whole dispatch, including the
  /// 404/405 synthesis, so a cross-cutting concern (CORS preflight, access log)
  /// covers unmatched requests too.
  late final Handler<E> _appHandler;

  FutureOr<Response> dispatch(TransportRequest request) {
    final List<String> segments;
    try {
      segments = _decodedSegments(request.uri);
    } on FormatException {
      // `uri.pathSegments` decodes lazily, so a percent-escape that is not
      // valid UTF-8 (`/%c0%af`) throws here — before the guard below, and
      // before any middleware exists to see it. Answered here rather than
      // inside the guard because there is no Context yet: building one needs
      // the segments this just failed to produce.
      return Response.json(const {
        'error': 'malformed percent-encoding in request path',
      }, status: 400);
    }
    final captured = <String>[];
    final (compiled, allowed) = _walk(
      _root,
      segments,
      0,
      request.method,
      captured,
    );
    final reqId = _reqId();
    final template = compiled?.template;
    // A capture-less route (the common case) needs no per-request map: reuse a
    // shared const empty one rather than allocate a growable map every request.
    // `c.param` on an unknown name still throws its ArgumentError either way.
    final captureNames = compiled?.captureNames;
    final params = (captureNames == null || captureNames.isEmpty)
        ? const <String, String>{}
        : <String, String>{
            for (var i = 0; i < captureNames.length; i++)
              captureNames[i]: captured[i],
          };
    final ctx =
        RequestCtx<E>(
            env: env,
            method: request.method,
            uri: request.uri,
            headers: request.headers,
            // Lazy so dispatch never pays the peer-address syscall unasked: the
            // resolver runs at most once, on first `c.remoteAddress`, and
            // RequestCtx caches the result.
            remoteAddress: () => request.remoteAddress,
            params: params,
            orderedCaptures: captured,
            // The raw request path never reaches the `route` log field — an
            // unmatched request (attacker-controlled path) logs the same fixed
            // placeholder every time, keeping this dimension bounded. The raw
            // path is still available to anyone who genuinely needs it via
            // `c.uri`, just never as a route-shaped, label-bound value.
            log: baseLog.withFields({
              'reqId': reqId,
              'route': template ?? unmatchedRoute,
            }),
            maxBodyBytes: maxBodyBytes,
            body: request.bodyStream,
          )
          ..matched = compiled?.handler
          ..matchedDoc = compiled?.doc
          ..matchedTemplate = template
          ..pathMatched = allowed != null
          ..allowedMethods = allowed == null ? const [] : allowed.toList();
    final c = Context<E>(ctx);
    // Client-disconnect → cooperative cancellation. abort() is idempotent, so a
    // later timeout (or vice versa) is harmless; a never-completing `closed`
    // (transports that can't detect disconnect) simply never fires.
    unawaited(request.closed.then((_) => ctx.abort()));
    return guard(() => _appHandler(c), (e, st) => _fallback(e, st, ctx));
  }

  /// The innermost handler: the matched route, or the 404/405 response.
  FutureOr<Response> _terminal(Context<E> c) {
    final raw = ctxOf(c);
    final handler = raw.matched;
    if (handler != null) return handler(c);
    if (raw.pathMatched) {
      // RFC 9110 §15.5.6: a 405 must advertise the methods the target path
      // does support, so the client need not probe for them.
      return Response.json(
        {'error': 'method not allowed'},
        status: 405,
        headers: {
          'allow': [raw.allowedMethods.join(', ')],
        },
      );
    }
    return Response.json({'error': 'not found'}, status: 404);
  }

  /// The last-resort fallback, always applied: `KetaException` maps to its
  /// status with a JSON error body, anything else to 500 with the error logged
  /// and no detail leaked.
  Response _fallback(Object error, StackTrace st, RequestCtx<E> ctx) {
    if (error is KetaException) {
      return Response.json({'error': error.message}, status: error.status);
    }
    ctx.log.error('unhandled exception', error, st);
    return Response(500, body: '');
  }

  /// A 128-bit request id as 32 lowercase hex chars.
  ///
  /// [Random.secure] is required, not incidental: a request id feeds the
  /// log/trace correlation dimension, and an id an attacker can predict or
  /// forge lets them collide with or spoof another request's series.
  String _reqId() {
    const hex = '0123456789abcdef';
    final out = Uint8List(32);
    for (var w = 0; w < 4; w++) {
      var v = _random.nextInt(0x100000000); // 32 bits per draw
      // Fill this word's 8 hex chars right-to-left (least-significant nibble
      // last), so the rendered value matches the drawn integer's big-endian hex.
      for (var i = 7; i >= 0; i--) {
        out[w * 8 + i] = hex.codeUnitAt(v & 0xf);
        v >>= 4;
      }
    }
    return String.fromCharCodes(out);
  }
}

/// Depth-first match, literal before capture, with backtracking so a failed
/// literal branch still lets a capture branch match. Returns the compiled route
/// (or null) and the set of methods registered on any route sharing this path
/// (null when no route shares it — the 404/405 discriminator, and the source of
/// the 405 `Allow` header). The set is a union: a literal and a capture branch
/// can both terminate on the request path, so their methods together describe
/// what the target path supports.
(_Compiled<E>?, Set<String>?) _walk<E>(
  _TrieNode<E> node,
  List<String> segments,
  int i,
  String method,
  List<String> captured,
) {
  if (i == segments.length) {
    if (node.methods.isEmpty) return (null, null);
    final compiled = node.methods[method];
    // On a method hit dispatch returns the route and never reads the allowed
    // set — only the 404/405 path does — so materialize the key-set solely on a
    // miss and hand a hit a shared const empty set instead of allocating one.
    if (compiled != null) return (compiled, const <String>{});
    return (null, node.methods.keys.toSet());
  }
  final seg = segments[i];
  Set<String>? allowed;
  final literal = node.literals[seg];
  if (literal != null) {
    final (route, methods) = _walk(literal, segments, i + 1, method, captured);
    if (route != null) return (route, methods);
    // `allowed` is provably null here — the capture branch below is the only
    // other writer and it runs after — so nothing needs spreading in.
    if (methods != null) allowed = {...methods};
  }
  final capture = node.capture;
  if (capture != null) {
    captured.add(seg);
    final (route, methods) = _walk(capture, segments, i + 1, method, captured);
    if (route != null) return (route, methods);
    captured.removeLast();
    if (methods != null) allowed = {...?allowed, ...methods};
  }
  return (null, allowed);
}

/// Matchable path segments, percent-decoded, with empty segments dropped so a
/// trailing slash and interior `//` stay tolerant. `uri.pathSegments` decodes
/// each segment and keeps `%2F` inside a single segment.
List<String> _decodedSegments(Uri uri) => [
  for (final s in uri.pathSegments)
    if (s.isNotEmpty) s,
];

/// A running server.
abstract interface class Server {
  /// Stops accepting requests, waits out in-flight work up to [grace], closes
  /// the env, and flushes logs.
  Future<void> shutdown({Duration grace});
}

/// Releases an env and its log — the one place that happens.
///
/// Every path that stops owning the pair runs this: a startup that failed
/// before binding, a failed worker spawn, either `Server.shutdown`, and a
/// worker's own exit. Skipping it anywhere leaves a process that will not exit
/// rather than an error anyone sees.
///
/// The `finally` is load-bearing: `env.close()` can throw (a pool that fails to
/// drain), and the flush and timer dispose must still run, or the log lines
/// that explain the failure are lost and the process hangs on the way out.
Future<void> _teardown<E>(E env, Log log) async {
  try {
    if (env is Disposable) await (env as Disposable).close();
  } finally {
    await log.flush();
    if (log is StdoutLog) log.dispose();
  }
}

class _Server<E>(
  final E env,
  final Log _baseLog,
  final TransportServer _transport,
) implements Server {
  @override
  Future<void> shutdown({Duration grace = const Duration(seconds: 30)}) async {
    await _transport.close(grace: grace);
    await _teardown(env, _baseLog);
  }
}

/// A handle to a spawned worker isolate, its shutdown control port, and the
/// port over which the isolate reports its own death.
class _Worker(
  /// Carries the isolate's `onError` payload and its `onExit` signal. Held open
  /// for the worker's whole life: it is the only channel on which a worker can
  /// say it died, and a `shared: true` listener leaves the accept set silently,
  /// so without it the process serves on N-1 isolates with nothing logged and
  /// shutdown spends the full grace awaiting an ack from an isolate that is
  /// gone.
  final ReceivePort events,
) {
  late final Isolate isolate;
  late final SendPort control;

  /// Set when the isolate reports that it is gone. A dead worker is not sent
  /// to, not waited for, and not killed.
  bool dead = false;

  void kill() {
    if (!dead) isolate.kill(priority: Isolate.immediate);
    events.close();
  }
}

/// The server for [App.serve] with `isolates > 1`: worker 0 runs here, the rest
/// in spawned isolates driven over control ports.
class _MultiServer<E>(
  final E _env,
  final Log _baseLog,
  final TransportServer _transport,
  final List<_Worker> _workers,
) implements Server {
  @override
  Future<void> shutdown({Duration grace = const Duration(seconds: 30)}) async {
    final ports = <ReceivePort>[];
    final acks = <Future<void>>[];
    for (final worker in _workers) {
      // A worker that already died has no one to receive the request and no ack
      // to give; waiting on it would burn the whole `grace + 5s` for nothing.
      if (worker.dead) continue;
      final ack = ReceivePort();
      ports.add(ack);
      worker.control.send((ack.sendPort, grace.inMilliseconds));
      acks.add(ack.first.then((_) {}));
    }
    try {
      await _transport.close(grace: grace);
      await _teardown(_env, _baseLog);
    } finally {
      // Reached even if the env refused to close: the ports and the isolates
      // below are what decide whether this process can exit at all, and a
      // failed drain is no reason to strand them.
      await Future.wait(
        acks,
      ).timeout(grace + const Duration(seconds: 5), onTimeout: () => const []);
      // Close every ack port whether or not the ack arrived — an un-closed
      // ReceivePort keeps this isolate alive and hangs the process.
      for (final port in ports) {
        port.close();
      }
      for (final worker in _workers) {
        worker.kill();
      }
    }
  }
}

Future<_Worker> _spawnWorker<E>(
  App<E> app,
  Future<E> Function() boot,
  int port,
  int maxBodyBytes,
  Log log,
  Transport Function()? transportFactory,
) async {
  final ready = ReceivePort();
  final worker = _Worker(ReceivePort());
  final failed = Completer<Object?>();
  var bound = false;
  // One listener for the isolate's whole life, rather than a `first` that
  // consumes the port: before it binds, a message means the spawn failed;
  // after, it means the worker died and the process is now serving on one
  // fewer isolate. Reporting that is the framework's part — restarting is the
  // supervisor's, which is why nothing here tries to.
  worker.events.listen((Object? message) {
    if (!bound) {
      if (!failed.isCompleted) failed.complete(message);
      return;
    }
    if (worker.dead) return;
    worker.dead = true;
    // `onError` sends [error, stackTraceString]; `onExit` sends null.
    final payload = message is List && message.isNotEmpty
        ? message.first
        : null;
    log.error(
      'worker isolate died; serving continues with one fewer listener',
      payload,
      null,
      {
        if (message is List && message.length > 1)
          'workerStack': '${message[1]}',
      },
    );
  });
  try {
    final isolate = await Isolate.spawn(
      _workerEntry<E>,
      (app, boot, port, maxBodyBytes, ready.sendPort, transportFactory),
      onError: worker.events.sendPort,
      onExit: worker.events.sendPort,
      errorsAreFatal: true,
    );
    // Whichever comes first: the child's control port (bound) or an error.
    final control = await Future.any([
      ready.first,
      failed.future.then<Object?>(
        (e) => throw StateError('worker failed to start: $e'),
      ),
    ]);
    worker
      ..isolate = isolate
      ..control = control as SendPort;
    bound = true;
    return worker;
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    worker.events.close();
    throw StateError(
      'serve(isolates > 1) requires a sendable boot and handlers: $e',
    );
  } catch (_) {
    worker.events.close();
    rethrow;
  } finally {
    ready.close();
  }
}

Future<void> _workerEntry<E>(
  (App<E>, Future<E> Function(), int, int, SendPort, Transport Function()?)
  args,
) async {
  final (app, boot, port, maxBodyBytes, ready, transportFactory) = args;
  final env = await boot();
  final fallbackLog = env is HasLog ? null : StdoutLog();
  final router = app.compile(env, maxBodyBytes: maxBodyBytes, log: fallbackLog);
  // Each worker builds its own transport from the factory, which is why the
  // factory (and not an instance) is what crosses the isolate boundary — the
  // whole point of the parameter. Without one this is the default H1 transport,
  // exactly as before.
  final t =
      transportFactory?.call() ??
      H1Transport(
        onError: (e, st) => router.baseLog.error('transport error', e, st),
      );
  final transport = await t.bind(port, router.dispatch);

  final control = ReceivePort();
  ready.send(control.sendPort);
  final (SendPort ack, int graceMs) = await control.first as (SendPort, int);
  try {
    await transport.close(grace: Duration(milliseconds: graceMs));
    await _teardown(env, router.baseLog);
  } finally {
    // The parent is waiting on this ack with a bounded timeout; a worker whose
    // env refused to close must still say so, or it costs the whole grace
    // window before the parent gives up on it.
    control.close();
    ack.send(null);
  }
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
