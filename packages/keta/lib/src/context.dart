library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'log.dart';
import 'response.dart';

/// A typed, identity-compared key for per-request values.
///
/// Keys compare by identity, so a `const` constructor is forbidden: const
/// canonicalization would fuse separate declarations into one instance and
/// collide. [name] appears in logs and error messages only.
final class Key<T> {
  final String name;

  Key(this.name);
}

/// The mutable per-request state behind [Context].
///
/// Public within the package so the router and middleware can populate it, but
/// never exported: user code reaches it only through [Context].
class RequestCtx<E> {
  final E env;
  final String method;
  final Uri uri;

  /// The matched route template (e.g. `/users/:id`), for low-cardinality logs,
  /// metrics, and span names.
  final String route;

  final Map<String, String> headers;
  final String remoteAddress;

  /// Captured parameters by name, for `c.param`.
  final Map<String, String> params;

  /// Captured parameters in path order, for typed-DSL tuple construction.
  final List<String> orderedCaptures;

  /// Per-request logger: `env.log` with reqId and route already baked in.
  final Log log;

  final int maxBodyBytes;

  final Stream<List<int>> _bodySource;
  final Map<Key<Object?>, Object?> _store = {};
  final Completer<void> _aborted = Completer<void>();

  List<int>? _bytes;
  Object? _json;
  bool _jsonDecoded = false;
  bool _streamTaken = false;

  /// The matched route's composed handler, or null when nothing matched — set
  /// by dispatch so app-level middleware can wrap the 404/405 synthesis too.
  FutureOr<Response> Function(Context<E>)? matched;

  /// Whether some route shares this path (distinguishes 405 from 404).
  bool pathMatched = false;

  RequestCtx({
    required this.env,
    required this.method,
    required this.uri,
    required this.route,
    required this.headers,
    required this.remoteAddress,
    required this.params,
    required this.orderedCaptures,
    required this.log,
    required this.maxBodyBytes,
    required Stream<List<int>> body,
  }) : _bodySource = body;

  Future<void> get aborted => _aborted.future;

  /// Signals cooperative cancellation (timeout fired or client disconnected).
  /// Idempotent.
  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
  }

  T param<T>(String name) {
    final raw = params[name];
    if (raw == null) {
      throw ArgumentError.value(name, 'name', 'unknown path parameter');
    }
    return _parseParam<T>(raw, name);
  }

  T _parseParam<T>(String raw, String name) {
    try {
      if (T == String) return raw as T;
      if (T == int) return int.parse(raw) as T;
      if (T == double) return double.parse(raw) as T;
      if (T == bool) {
        return switch (raw) {
          'true' => true as T,
          'false' => false as T,
          _ => throw FormatException('expected bool', raw),
        };
      }
    } on FormatException {
      throw KetaException(400, 'invalid path parameter "$name"');
    }
    throw ArgumentError('unsupported param type $T for "$name"');
  }

  T get<T>(Key<T> key) {
    if (!_store.containsKey(key)) {
      throw StateError('no value bound for Key<$T>("${key.name}")');
    }
    return _store[key] as T;
  }

  T? tryGet<T>(Key<T> key) => _store[key] as T?;

  void set<T>(Key<T> key, T value) => _store[key] = value;

  Future<List<int>> bodyBytes() async {
    final cached = _bytes;
    if (cached != null) return cached;
    if (_streamTaken) {
      throw StateError('body stream already taken; cannot read bytes');
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in _bodySource) {
      total += chunk.length;
      if (total > maxBodyBytes) {
        throw KetaException(413, 'request body exceeds $maxBodyBytes bytes');
      }
      builder.add(chunk);
    }
    return _bytes = builder.takeBytes();
  }

  Future<Object?> body() async {
    if (_jsonDecoded) return _json;
    final bytes = await bodyBytes();
    _jsonDecoded = true;
    if (bytes.isEmpty) return _json = null;
    try {
      return _json = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw KetaException(400, 'invalid JSON body', e.message);
    }
  }

  Stream<List<int>> bodyStream() {
    final cached = _bytes;
    if (cached != null) return Stream.value(cached);
    if (_streamTaken) throw StateError('body stream already taken');
    _streamTaken = true;
    return _bodySource;
  }
}

/// The request/response surface handed to every handler and middleware.
///
/// A zero-cost wrapper over [RequestCtx]: it adds no allocation and exposes
/// exactly the members user code should touch.
extension type Context<E>(RequestCtx<E> _raw) {
  E get env => _raw.env;
  String get method => _raw.method;
  Uri get uri => _raw.uri;

  /// The matched route template (e.g. `/users/:id`).
  String get route => _raw.route;

  /// The peer address as seen by the Transport. Resolving the real client
  /// behind a proxy (X-Forwarded-For) is the application's responsibility.
  String get remoteAddress => _raw.remoteAddress;

  Log get log => _raw.log;

  /// Completes when the request is cancelled (timeout or client disconnect).
  /// Observing it is optional — cancellation is cooperative.
  Future<void> get aborted => _raw.aborted;

  /// The header named [name] (case-insensitive), or null.
  String? header(String name) => _raw.headers[name.toLowerCase()];

  /// All request headers, with lower-cased names. Read-only.
  Map<String, String> get headers => Map.unmodifiable(_raw.headers);

  /// The path parameter [name] parsed as `T` (String, int, double, or bool).
  /// An unsupported `T` is an `ArgumentError`; a parse failure is a
  /// `KetaException(400)`.
  T param<T>(String name) => _raw.param<T>(name);

  /// The value bound to [key]. Unset is a `StateError` (a programming error).
  T get<T>(Key<T> key) => _raw.get<T>(key);

  T? tryGet<T>(Key<T> key) => _raw.tryGet<T>(key);

  void set<T>(Key<T> key, T value) => _raw.set<T>(key, value);

  /// The request body decoded as JSON (UTF-8 then `jsonDecode`), cached across
  /// calls. Invalid JSON is a `KetaException(400)`; exceeding the body limit is
  /// a `KetaException(413)`.
  Future<Object?> body() => _raw.body();

  /// The raw request body, subject to the same size limit as [body].
  Future<List<int>> bodyBytes() => _raw.bodyBytes();

  /// The request body as an unbuffered stream. Enforcing a size limit is the
  /// caller's responsibility; use this for large uploads.
  Stream<List<int>> bodyStream() => _raw.bodyStream();

  /// A JSON response: `jsonEncode(body)` with `application/json`.
  Response json(Object? body, [int status = 200]) =>
      Response.json(body, status);

  /// A `text/plain; charset=utf-8` response.
  Response text(String body, [int status = 200]) => Response.text(body, status);
}

/// Unwraps a [Context] to its backing [RequestCtx] for package-internal use
/// (typed dispatch, middleware). Not exported.
RequestCtx<E> ctxOf<E>(Context<E> c) => c._raw;
