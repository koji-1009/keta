library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'header.dart';
import 'log.dart';
import 'response.dart';
import 'route_doc.dart';

/// The fixed label logged and reported for the route dimension (`c.log`'s
/// baked `route` field, `accessLog`'s line, and any metrics/span exporter
/// reading [Context.routeTemplate]) when a request matches no route.
///
/// A request that 404s or 405s carries an attacker-controlled, unbounded path;
/// substituting it into a low-cardinality dimension would let a client mint
/// one log/metric/span series per path it probes. This single fixed value
/// keeps the dimension bounded regardless of what a client sends — one
/// constant, so every consumer agrees on the same label rather than each
/// coining its own.
const String unmatchedRoute = '(unmatched)';

/// A typed, identity-compared key for per-request values.
///
/// Keys compare by identity, so a `const` constructor is forbidden: const
/// canonicalization would fuse separate declarations into one instance and
/// collide. [name] appears in logs and error messages only.
final class Key<T> {
  Key(this.name);
  final String name;
}

/// The mutable per-request state behind [Context].
///
/// Public within the package so the router and middleware can populate it, but
/// never exported: user code reaches it only through [Context].
class RequestCtx<E> {
  RequestCtx({
    required this.env,
    required this.method,
    required this.uri,
    required this.headers,
    required String Function() remoteAddress,
    required this.params,
    required this.orderedCaptures,
    required this.log,
    required this.maxBodyBytes,
    required Stream<List<int>> body,
  }) : _resolveRemoteAddress = remoteAddress,
       _bodySource = body;
  final E env;
  final String method;
  final Uri uri;

  final Map<String, List<String>> headers;

  /// Resolved on first [remoteAddress] read and cached, because most handlers
  /// never read it and resolving it eagerly cost a measured 10.6% of hot-path
  /// CPU (the transport's peer-address syscall). See [Context.remoteAddress].
  final String Function() _resolveRemoteAddress;
  String? _remoteAddressResolved;

  /// The peer address as seen by the Transport, resolved lazily and cached.
  /// After the connection is torn down it may resolve to `''` (the transport's
  /// `?? ''` fallback), and that value — like any other — is then cached, so
  /// repeated reads within one request always agree.
  String get remoteAddress =>
      _remoteAddressResolved ??= _resolveRemoteAddress();

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

  Uint8List? _bytes;
  Object? _json;
  bool _jsonDecoded = false;
  bool _streamTaken = false;
  Object? _bodyError;
  StackTrace? _bodyStack;
  Map<String, String>? _cookies;

  /// The matched route's composed handler, or null when nothing matched — set
  /// by dispatch so app-level middleware can wrap the 404/405 synthesis too.
  FutureOr<Response> Function(Context<E>)? matched;

  /// The matched route's [RouteDoc], or null. The core carries the declaration
  /// it owns; [enforceSecurity] reads its `security` and the OpenAPI walk reads
  /// the rest.
  RouteDoc? matchedDoc;

  /// Whether some route shares this path (distinguishes 405 from 404).
  bool pathMatched = false;

  /// The matched route's template (e.g. `/users/:id`), or null when nothing
  /// matched — the bounded-cardinality dimension for logs, metrics, and spans.
  /// A raw request path never substitutes for it; see [Context.routeTemplate].
  String? matchedTemplate;

  /// The methods registered on the matched path, for a synthesized 405's
  /// `Allow` header (RFC 9110 §15.5.6). Empty when no route shares the path.
  List<String> allowedMethods = const [];

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
    return _parse<T>(raw, 'path', name);
  }

  T query<T>(String name) {
    final raw = uri.queryParameters[name];
    if (raw == null) throw BadRequest('missing query parameter "$name"');
    return _parse<T>(raw, 'query', name);
  }

  T? tryQuery<T>(String name) {
    final raw = uri.queryParameters[name];
    return raw == null ? null : _parse<T>(raw, 'query', name);
  }

  List<T> queryAll<T>(String name) => [
    for (final raw in uri.queryParametersAll[name] ?? const <String>[])
      _parse<T>(raw, 'query', name),
  ];

  T _parse<T>(String raw, String kind, String name) {
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
      throw BadRequest('invalid $kind parameter "$name"');
    }
    throw ArgumentError('unsupported $kind parameter type $T for "$name"');
  }

  T get<T>(Key<T> key) {
    if (!_store.containsKey(key)) {
      throw StateError('no value bound for Key<$T>("${key.name}")');
    }
    return _store[key] as T;
  }

  T? tryGet<T>(Key<T> key) => _store[key] as T?;

  void set<T>(Key<T> key, T value) => _store[key] = value;

  String? cookie(String name) => cookies[name];

  /// Parses the `Cookie` header into name→value pairs, once per request.
  ///
  /// RFC 6265 §4.2.1 pair syntax: pairs are `;`-separated, whitespace around a
  /// pair is trimmed, the name/value split is the first `=`. Cookie values are
  /// opaque octets, so nothing is decoded beyond that. A malformed pair (no
  /// `=`, or an empty name) is skipped — never a 500 — and the first occurrence
  /// of a duplicate name wins.
  Map<String, String> get cookies => _cookies ??= _parseCookies();

  Map<String, String> _parseCookies() {
    final values = headers['cookie'];
    if (values == null || values.isEmpty) return const {};
    final result = <String, String>{};
    for (final headerValue in values) {
      for (final raw in headerValue.split(';')) {
        final pair = raw.trim();
        final eq = pair.indexOf('=');
        // eq <= 0 covers both "no =" (-1) and an empty name (0).
        if (eq <= 0) continue;
        final name = pair.substring(0, eq).trimRight();
        if (name.isEmpty) continue;
        result.putIfAbsent(name, () => pair.substring(eq + 1).trim());
      }
    }
    return result;
  }

  Future<Uint8List> bodyBytes() async {
    final cached = _bytes;
    if (cached != null) return cached;
    // A prior failed read is sticky: the single-subscription source is spent,
    // so a re-read must reproduce that failure — the 413 for an over-limit
    // body, or the original I/O error for a broken stream — rather than surface
    // an opaque "Stream already listened" StateError (which would escape as an
    // unrelated 500).
    final priorError = _bodyError;
    if (priorError != null) {
      Error.throwWithStackTrace(priorError, _bodyStack ?? StackTrace.current);
    }
    if (_streamTaken) {
      throw StateError('body stream already taken; cannot read bytes');
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final chunk in _bodySource) {
        total += chunk.length;
        if (total > maxBodyBytes) {
          throw PayloadTooLarge('request body exceeds $maxBodyBytes bytes');
        }
        builder.add(chunk);
      }
    } catch (e, st) {
      // Any failure draining the body sticks — a KetaException (413) or an
      // I/O error from the transport alike. The source cannot be listened to
      // twice, so recording the failure is the only way a re-read stays
      // deterministic instead of collapsing into "Stream already listened".
      _bodyError = e;
      _bodyStack = st;
      _streamTaken = true; // the source is consumed; block a re-listen
      rethrow;
    }
    return _bytes = builder.takeBytes();
  }

  Future<Object?> body() async {
    if (_jsonDecoded) return _json;
    final bytes = await bodyBytes();
    if (bytes.isEmpty) {
      _jsonDecoded = true;
      return _json = null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      _jsonDecoded = true; // cache only on success, so a retry still throws 400
      return _json = decoded;
    } on FormatException catch (e) {
      throw BadRequest('invalid JSON body', e.message);
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

  /// The matched route's template (e.g. `/users/:id`), or null when nothing
  /// matched. THE bounded-cardinality dimension for logs, metrics, and spans —
  /// the raw request path is attacker-controlled and unbounded, so it never
  /// substitutes for this and is not exposed as a route-shaped accessor at
  /// all; read [uri] directly if the raw path itself is genuinely needed.
  String? get routeTemplate => _raw.matchedTemplate;

  /// The peer address as seen by the Transport. Resolving the real client
  /// behind a proxy (X-Forwarded-For) is the application's responsibility.
  ///
  /// Resolved lazily on first read and cached: most handlers never read it, and
  /// resolving it eagerly for every request cost a measured 10.6% of hot-path
  /// CPU (the H1 transport reads it via a per-call `connectionInfo` syscall). A
  /// handler that never touches it pays nothing; one that reads it repeatedly
  /// pays the resolve once and sees a consistent value thereafter. If the
  /// connection has already been torn down when it is first read, it may resolve
  /// to `''` — the transport's existing `?? ''` fallback — which is then the
  /// cached value.
  String get remoteAddress => _raw.remoteAddress;

  Log get log => _raw.log;

  /// The matched route's [RouteDoc], or null. The declaration is core's own:
  /// [enforceSecurity] reads its `security` and the OpenAPI walk reads the rest.
  RouteDoc? get routeDoc => _raw.matchedDoc;

  /// Completes when the request is cancelled (timeout or client disconnect).
  /// Observing it is optional — cancellation is cooperative.
  Future<void> get aborted => _raw.aborted;

  /// The first value of the header named [name] (case-insensitive), or null.
  String? header(String name) {
    final values = _raw.headers[name.toLowerCase()];
    return (values == null || values.isEmpty) ? null : values.first;
  }

  /// Every value of the header named [name] (case-insensitive), in order; empty
  /// when absent. The multi-value counterpart of [header].
  List<String> headerAll(String name) =>
      _raw.headers[name.toLowerCase()] ?? const [];

  /// All request headers: lower-cased names to their ordered values. Read-only.
  Map<String, List<String>> get headers => Map.unmodifiable(_raw.headers);

  /// The header [accessor] names, decoded — a [BadRequest] when it is absent
  /// or malformed.
  ///
  /// Required-ness is which accessor you call, not a flag, exactly as it is for
  /// query parameters: this is the required form, [tryHeaderAs] the optional
  /// one. A malformed value is the client's defect either way, so it is a 400
  /// from both.
  T headerAs<T extends Object>(HeaderAccessor<T> accessor) {
    final value = tryHeaderAs(accessor);
    if (value == null) throw BadRequest('missing header "${accessor.name}"');
    return value;
  }

  /// The header [accessor] names, decoded, or null when it is absent.
  ///
  /// Null also means "present but to be ignored" for the headers whose RFC says
  /// so — `Range` is the one keta models: a server that cannot parse a Range
  /// must serve the whole representation rather than refuse the request, so an
  /// unreadable one reads as absent here instead of raising.
  T? tryHeaderAs<T extends Object>(HeaderAccessor<T> accessor) {
    final values = _raw.headers[accessor.name] ?? const <String>[];
    if (values.isEmpty) return null;
    try {
      return accessor.codec.decode(values);
    } on Object catch (error) {
      if (isIgnorableHeader(error)) return null;
      rethrow;
    }
  }

  /// The request cookie named [name], or null. Parsed from the `Cookie` header
  /// (RFC 6265 pair syntax); a malformed pair is skipped, never a 500.
  String? cookie(String name) => _raw.cookie(name);

  /// All request cookies as name→value, parsed once per request. Malformed
  /// pairs are skipped and the first occurrence of a duplicate name wins.
  Map<String, String> get cookies => _raw.cookies;

  /// The path parameter [name] parsed as `T` (String, int, double, or bool).
  /// An unsupported `T` is an `ArgumentError`; a parse failure is a [BadRequest].
  T param<T>(String name) => _raw.param<T>(name);

  /// The query parameter [name] parsed as `T` (String, int, double, or bool) —
  /// the same type-parsing contract as [param], but NOT the same presence
  /// guarantee: a path capture is always present because the route matched,
  /// whereas a query parameter may simply be absent. Absence is deliberately a
  /// [BadRequest] (400), not null. Required-ness is expressed by which accessor
  /// you call — [query] declares the parameter mandatory, [tryQuery] declares it
  /// optional — rather than by a separate flag, so a handler that reads [query]
  /// has said "this must be here", and a missing one is a malformed request that
  /// earns the same 400 a bad value does. By design, not an oversight.
  T query<T>(String name) => _raw.query<T>(name);

  /// The query parameter [name] as `T`, or null when absent (the optional form).
  T? tryQuery<T>(String name) => _raw.tryQuery<T>(name);

  /// Every value of a repeated query key (`?tag=a&tag=b`) as `T`; empty when
  /// absent.
  List<T> queryAll<T>(String name) => _raw.queryAll<T>(name);

  /// The value bound to [key]. Unset is a `StateError` (a programming error).
  T get<T>(Key<T> key) => _raw.get<T>(key);

  T? tryGet<T>(Key<T> key) => _raw.tryGet<T>(key);

  void set<T>(Key<T> key, T value) => _raw.set<T>(key, value);

  /// The request body decoded as JSON (UTF-8 then `jsonDecode`), cached across
  /// calls. Invalid JSON is a [BadRequest]; exceeding the body limit is a
  /// [PayloadTooLarge].
  Future<Object?> body() => _raw.body();

  /// The raw request body, subject to the same size limit as [body]. Typed
  /// [Uint8List] rather than `List<int>` deliberately: the buffer is already
  /// contiguous bytes, and the concrete static type is what lets an AOT-compiled
  /// consumer loop read it unboxed (measured ~30% faster than the same loop
  /// dispatching through the `List<int>` interface).
  Future<Uint8List> bodyBytes() => _raw.bodyBytes();

  /// The request body as an unbuffered stream. Enforcing a size limit is the
  /// caller's responsibility; use this for large uploads.
  Stream<List<int>> bodyStream() => _raw.bodyStream();

  /// A JSON response: `jsonEncode(body)` with `application/json`. Extra
  /// [headers] merge over the content type.
  Response json(
    Object? body, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => Response.json(body, status: status, headers: headers);

  /// A `text/plain; charset=utf-8` response. Extra [headers] merge over the
  /// content type.
  Response text(
    String body, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => Response.text(body, status: status, headers: headers);
}

/// Unwraps a [Context] to its backing [RequestCtx] for package-internal use
/// (typed dispatch, middleware). Not exported.
RequestCtx<E> ctxOf<E>(Context<E> c) => c._raw;
