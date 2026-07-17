library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io show gzip;

import 'app.dart';
import 'chain.dart';
import 'context.dart';
import 'response.dart';

/// Logs one line per request on completion: method, status, and elapsed
/// milliseconds (reqId and route are already baked into `c.log`). Place it
/// outermost so it times the whole chain.
Middleware<E> accessLog<E>() => (Context<E> c, Handler<E> next) {
  final watch = Stopwatch()..start();
  void emit(int status) {
    watch.stop();
    c.log.info('request', {
      'method': c.method,
      'status': status,
      'ms': watch.elapsedMilliseconds,
    });
  }

  return guard<Response>(
    () => chain(next(c), (Response r) {
      emit(r.status);
      return r;
    }),
    (error, st) {
      emit(error is KetaException ? error.status : 500);
      Error.throwWithStackTrace(error, st);
    },
  );
};

/// Converts a thrown [KetaException] into its status with a `{"error": ...}`
/// body, and any other exception into 500 with the error (and stack) logged and
/// no detail leaked. A customization point, not a precondition for safety — the
/// core applies the same conversion as a last resort regardless.
Middleware<E> recover<E>() => (Context<E> c, Handler<E> next) {
  return guard<Response>(() => next(c), (error, st) {
    if (error is KetaException) {
      // A declared status is an expected outcome, not an incident, so it is not
      // logged as one. Its [KetaException.detail] is: detail exists precisely
      // to say what the client must not be told, and it is worth nothing if
      // nothing ever reads it. Without this an adapter that turns a driver
      // error into, say, a Conflict would take the diagnosis down with it —
      // the operator would see the status and never learn which constraint
      // collided.
      if (error.detail != null) {
        c.log.warn(error.message, {
          'status': error.status,
          'detail': '${error.detail}',
        });
      }
      return Response.json({'error': error.message}, status: error.status);
    }
    c.log.error('unhandled exception', error, st);
    return Response(500, body: '');
  });
};

/// Attaches CORS headers and answers preflight requests. Stateless and pure: an
/// origin is allowed when it is listed or [allowOrigins] contains `'*'`.
///
/// A preflight is an `OPTIONS` request carrying `access-control-request-method`;
/// it is answered here with 204. A plain `OPTIONS` (no such header) falls
/// through to the routes, so a user-registered `OPTIONS` handler stays
/// reachable. Echoing a specific (non-`'*'`) origin always adds `Vary: Origin`,
/// without which a shared cache could serve one origin's response to another.
///
/// [allowCredentials] projects `Access-Control-Allow-Credentials: true`;
/// [maxAge] projects `Access-Control-Max-Age` (seconds) onto the preflight; and
/// [exposeHeaders] projects `Access-Control-Expose-Headers` onto actual
/// responses.
Middleware<E> cors<E>({
  required List<String> allowOrigins,
  List<String> allowMethods = const [
    'GET',
    'POST',
    'PUT',
    'DELETE',
    'PATCH',
    'OPTIONS',
  ],
  List<String> allowHeaders = const ['content-type', 'authorization'],
  bool allowCredentials = false,
  Duration? maxAge,
  List<String> exposeHeaders = const [],
}) {
  final origins = allowOrigins.toSet();
  final wildcard = origins.contains('*');
  return (Context<E> c, Handler<E> next) {
    final origin = c.header('origin');
    final allowed = wildcard || (origin != null && origins.contains(origin));

    // Headers shared by preflight and actual responses when the origin passes.
    final base = <String, List<String>>{
      if (allowed) ...{
        'access-control-allow-origin': [wildcard ? '*' : origin!],
        // A specific echoed origin makes the response vary by Origin; the
        // wildcard is origin-independent and needs no Vary.
        if (!wildcard) 'vary': const ['Origin'],
        if (allowCredentials)
          'access-control-allow-credentials': const ['true'],
      },
    };

    final isPreflight =
        c.method == 'OPTIONS' &&
        c.header('access-control-request-method') != null;
    if (isPreflight) {
      return Response(
        204,
        headers: {
          ...base,
          if (allowed) ...{
            'access-control-allow-methods': [allowMethods.join(', ')],
            'access-control-allow-headers': [allowHeaders.join(', ')],
            if (maxAge != null)
              'access-control-max-age': ['${maxAge.inSeconds}'],
          },
        },
      );
    }

    return chain(next(c), (Response r) {
      // Merge onto the handler's headers, unioning Vary so a downstream
      // `Vary` (gzip's Accept-Encoding, etc.) is preserved rather than clobbered.
      final merged = {...r.headers};
      base.forEach((name, values) {
        if (name == 'vary' && merged['vary'] != null) {
          merged['vary'] = _unionVary(merged['vary']!, values);
        } else {
          merged[name] = values;
        }
      });
      if (allowed && exposeHeaders.isNotEmpty) {
        merged['access-control-expose-headers'] = [exposeHeaders.join(', ')];
      }
      // copyWith, not `Response(...)`: an upgrade response passing through here
      // (a WebSocket handshake behind app-wide cors) must keep its `upgrade`
      // field, which a fresh construction would silently drop — answering 101
      // without ever switching. See [Response.copyWith].
      return r.copyWith(headers: merged);
    });
  };
}

/// Fails a request that outlives [d] with a [GatewayTimeout] (504) and completes
/// `c.aborted`. Cancellation is cooperative and does NOT stop the handler: a
/// handler ignoring `c.aborted` runs to completion after the 504 is sent — its
/// side effects (writes, resource use) still happen, and its late result is
/// dropped with a warning. Observe `c.aborted` to abandon work early.
Middleware<E> timeout<E>(Duration d) => (Context<E> c, Handler<E> next) {
  final result = next(c);
  if (result is! Future<Response>) return result;

  final completer = Completer<Response>();
  final timer = Timer(d, () {
    if (completer.isCompleted) return;
    ctxOf(c).abort();
    completer.completeError(
      const GatewayTimeout('request timeout'),
      StackTrace.current,
    );
  });
  result.then(
    (r) {
      timer.cancel();
      if (completer.isCompleted) {
        c.log.warn('handler completed after timeout');
      } else {
        completer.complete(r);
      }
    },
    onError: (Object e, StackTrace st) {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(e, st);
    },
  );
  return completer.future;
};

/// Adds a strong `ETag` over a buffered response body and answers a matching
/// conditional `GET`/`HEAD` with `304 Not Modified`.
///
/// The tag is `"<hash>"`, hashed with FNV-1a (64-bit) over the body bytes. FNV
/// rather than SHA because Ring 0 has no crypto dependency (dart:io ships no
/// SHA) and a cache validator needs only a fast, well-distributed content
/// fingerprint, not collision resistance against an adversary — a caller who
/// controls the body already controls the response. Only 200 responses with a
/// buffered body (`String`/`List<int>`) are tagged; a `Stream` body passes
/// through untouched (its length and bytes are not known up front). An
/// `ETag` the handler already set is respected, not overwritten.
///
/// On a `GET`/`HEAD` whose `If-None-Match` matches (weak comparison per RFC 9110
/// §8.8.3.2 — a `W/`-prefix is ignored on both sides — plus `*` and
/// comma-separated lists), the response becomes a bodyless `304` carrying the
/// `ETag` and the non-content headers, with the content headers dropped per
/// RFC 9110 §15.4.5.
///
/// Ordering with [gzip]: register `gzip()` **before** `etag()` (gzip outer,
/// etag inner). The etag is then computed over the un-encoded (identity) body
/// and gzip encodes it afterwards, so the validator depends only on the
/// handler's own bytes — deterministic regardless of the compressor — which RFC
/// 9110 §8.8.3 permits ("computed pre-encoding"). Putting gzip inside etag
/// instead would make the tag depend on byte-exact compressor reproducibility.
Middleware<E> etag<E>() => (Context<E> c, Handler<E> next) {
  return chain(next(c), (Response r) {
    // An upgrade response switches protocols with an empty body and status 101;
    // there is nothing to tag or conditionally 304, and its `upgrade` field must
    // survive. Pass it through by identity rather than relying on the non-200
    // check below to skip it. (See [Response.copyWith] for why a rebuild here
    // would be a hazard.)
    if (r.upgrade != null) return r;
    final body = r.body;
    // A stream's bytes are not buffered; leave it and any non-200 untouched.
    if (body is! String && body is! List<int>) return r;
    if (r.status != 200) return r;

    final bytes = body is String ? utf8.encode(body) : body as List<int>;
    // Respect a handler-supplied validator: use it for the comparison and do
    // not overwrite it.
    final existing = r.headers['etag']?.first;
    final tag = existing ?? '"${_fnv1a64Hex(bytes)}"';

    final method = c.method;
    if ((method == 'GET' || method == 'HEAD') &&
        _ifNoneMatch(c.header('if-none-match'), tag)) {
      final headers = <String, List<String>>{};
      r.headers.forEach((name, values) {
        // A 304 carries validators and metadata but not content headers
        // (RFC 9110 §15.4.5) — the client keeps its cached representation.
        if (name == 'content-type' ||
            name == 'content-length' ||
            name == 'content-encoding') {
          return;
        }
        headers[name] = values;
      });
      headers['etag'] = [tag];
      return Response(304, headers: headers, body: '');
    }

    if (existing != null) return r;
    return r.copyWith(
      headers: {
        ...r.headers,
        'etag': [tag],
      },
    );
  });
};

/// True when [ifNoneMatch] (a request header value) matches [tag] under RFC 9110
/// §8.8.3.2 weak comparison: `*` matches any current representation, otherwise
/// any comma-separated entity-tag whose opaque form equals [tag]'s, ignoring a
/// `W/` weakness prefix on either side.
bool _ifNoneMatch(String? ifNoneMatch, String tag) {
  if (ifNoneMatch == null) return false;
  final want = _weakStrip(tag);
  for (final raw in ifNoneMatch.split(',')) {
    final candidate = raw.trim();
    if (candidate == '*') return true;
    if (_weakStrip(candidate) == want) return true;
  }
  return false;
}

String _weakStrip(String tag) => tag.startsWith('W/') ? tag.substring(2) : tag;

String _fnv1a64Hex(List<int> bytes) {
  // Dart's int is 64-bit two's complement on the native VM (keta's only target;
  // Ring 0 does not target the web), so the multiply wraps mod 2^64 exactly as
  // FNV-1a requires.
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash *= 0x100000001b3;
  }
  // Format as two unsigned 32-bit halves so a wrapped (negative) int still
  // renders as a stable 16-hex string.
  final hi = (hash >> 32) & 0xffffffff;
  final lo = hash & 0xffffffff;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// Compresses a buffered response body with gzip when the request advertises it
/// in `Accept-Encoding`, using dart:io's ZLib gzip codec (SDK only — Ring 0
/// stays zero-dependency).
///
/// A non-stream response gains `Vary: Accept-Encoding` (unioned with any
/// existing `Vary`, the same discipline as [cors]) because its representation is
/// negotiated on that header. Compression itself is skipped — the body passes
/// through unchanged — when the request does not accept gzip (including an
/// explicit `gzip;q=0`), the response is already `Content-Encoding`d, the status
/// is 204/304, or the body is smaller than [threshold] bytes (compressing a
/// tiny body spends more bytes than it saves). A `Stream` body passes through
/// entirely untouched (no `Vary`), since it is not buffered.
///
/// The compressed body is a `List<int>`, so the transport frames it with the
/// correct post-compression `Content-Length` — gzip runs before framing.
///
/// Ordering with [etag]: register `gzip()` **before** `etag()` (see [etag]).
Middleware<E> gzip<E>({
  int threshold = 1024,
}) => (Context<E> c, Handler<E> next) {
  return chain(next(c), (Response r) {
    // An upgrade response has an empty body and switches protocols; there is
    // nothing to compress and no representation to negotiate, so it must not
    // gain a spurious `Vary: Accept-Encoding` — and above all its `upgrade`
    // field must survive. Pass it through by identity. (See
    // [Response.copyWith] for why rebuilding it here would drop the switch.)
    if (r.upgrade != null) return r;
    final body = r.body;
    // A stream is not buffered; pass it through with nothing added.
    if (body is! String && body is! List<int>) return r;

    final headers = _varyAcceptEncoding(r.headers);

    final alreadyEncoded = r.headers.containsKey('content-encoding');
    final compressible =
        !alreadyEncoded &&
        r.status != 204 &&
        r.status != 304 &&
        _acceptsGzip(c.header('accept-encoding'));
    if (!compressible) {
      return r.copyWith(headers: headers);
    }

    final bytes = body is String ? utf8.encode(body) : body as List<int>;
    // Compressing a body below the threshold adds header overhead for no
    // real saving, so it is left as-is (but still Vary-tagged above).
    if (bytes.length < threshold) {
      return r.copyWith(headers: headers);
    }

    headers['content-encoding'] = const ['gzip'];
    return r.copyWith(headers: headers, body: io.gzip.encode(bytes));
  });
};

/// True when [acceptEncoding] advertises gzip with a non-zero q-value — an
/// explicit `gzip` token, or `*`, in either case not overridden by `;q=0`.
bool _acceptsGzip(String? acceptEncoding) {
  if (acceptEncoding == null) return false;
  for (final raw in acceptEncoding.split(',')) {
    final parts = raw.split(';');
    final coding = parts.first.trim().toLowerCase();
    if (coding != 'gzip' && coding != '*') continue;
    var q = 1.0;
    for (final param in parts.skip(1)) {
      final p = param.trim();
      if (p.startsWith('q=')) {
        q = double.tryParse(p.substring(2)) ?? 1.0;
      }
    }
    if (q > 0) return true;
  }
  return false;
}

/// Returns a mutable copy of [headers] with `Accept-Encoding` unioned into
/// `Vary`, preserving any value a downstream middleware already set.
Map<String, List<String>> _varyAcceptEncoding(
  Map<String, List<String>> headers,
) {
  final merged = {...headers};
  merged['vary'] = _unionVary(merged['vary'] ?? const [], const [
    'Accept-Encoding',
  ]);
  return merged;
}

/// Unions [additions] onto an existing `Vary` header's values, skipping any
/// addition already present (case-insensitively — header names, so `Origin`
/// and `origin` name the same thing). `Vary` is a set of header names, not a
/// log; a duplicate confers no extra meaning while bloating the header, so
/// every middleware that adds to it (here and [_varyAcceptEncoding]) shares
/// this one discipline rather than each risking its own.
List<String> _unionVary(List<String> existing, List<String> additions) {
  final merged = [...existing];
  for (final addition in additions) {
    if (!merged.any((v) => v.toLowerCase() == addition.toLowerCase())) {
      merged.add(addition);
    }
  }
  return merged;
}

/// A parsed W3C `traceparent` header.
class TraceContext {
  const TraceContext(this.traceId, this.parentId, this.flags);
  final String traceId;
  final String parentId;
  final int flags;

  /// Parses `version-traceId-parentId-flags` (W3C Trace Context §3.2), returning
  /// null on *any* violation so the caller treats a bad header as absent — never
  /// as an error. A garbage header must never surface as a 500; and since
  /// batching landed, a single malformed id that slipped through into an OTLP
  /// batch is enough for a strict collector to reject the whole batch, not just
  /// the one span, so this is deliberately strict rather than best-effort.
  ///
  /// Every field is enforced, not just the two lengths the old code checked:
  /// - version, traceId, parentId must be *lowercase* hex of their exact widths
  ///   (2/32/16) — the header is defined in lowercase, and echoing a mixed-case
  ///   or non-hex id (e.g. 32 `g`s) back downstream is exactly what a collector
  ///   rejects;
  /// - the all-zero traceId and all-zero parentId are the spec's reserved
  ///   "invalid" sentinels (§3.2.2.3), a present-but-meaningless id — rejected;
  /// - version `ff` is reserved/forbidden — rejected;
  /// - flags is exactly two hex digits. A bare `int.tryParse(radix: 16)` admits
  ///   a signed `-5` and a lone-digit `-5`-style width, none of which is a valid
  ///   8-bit flags octet, so the width/charset is checked before the parse.
  static TraceContext? parse(String header) {
    final parts = header.split('-');
    if (parts.length != 4) return null;
    final version = parts[0];
    final traceId = parts[1];
    final parentId = parts[2];
    final flagsHex = parts[3];
    // Version `ff` is reserved (a valid parser must reject it); every other
    // two-digit lowercase-hex version is accepted.
    if (!_isLowerHex(version, 2) || version == 'ff') return null;
    // traceId / parentId: exact-width lowercase hex, and never the reserved
    // all-zero sentinel that means "invalid id present".
    if (!_isLowerHex(traceId, 32) || _isAllZero(traceId)) return null;
    if (!_isLowerHex(parentId, 16) || _isAllZero(parentId)) return null;
    if (!_isLowerHex(flagsHex, 2)) return null;
    // Width and charset already verified above, so this parse cannot fail and
    // cannot be negative — exactly the two-hex-digit octet the spec defines.
    return TraceContext(traceId, parentId, int.parse(flagsHex, radix: 16));
  }

  /// True when [s] is exactly [length] characters, each a *lowercase* hex digit
  /// (`0`-`9` / `a`-`f`). Uppercase is intentionally rejected: the traceparent
  /// grammar is lowercase-only, and being lenient here would let a mixed-case id
  /// propagate into an OTLP batch a collector then rejects wholesale.
  static bool _isLowerHex(String s, int length) {
    if (s.length != length) return false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39; // 0-9
      final isLowerAf = c >= 0x61 && c <= 0x66; // a-f
      if (!isDigit && !isLowerAf) return false;
    }
    return true;
  }

  /// True when every character of [s] is `0` — the reserved all-zero traceId /
  /// parentId the spec defines as invalid, which a conforming parser rejects.
  static bool _isAllZero(String s) {
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) != 0x30) return false;
    }
    return true;
  }
}

/// The key under which [tracing] stores the extracted [TraceContext].
final Key<TraceContext> traceKey = Key<TraceContext>('trace');

/// Extracts a `traceparent` header into `c.get(traceKey)` when present. Export
/// of spans lives in keta_otel; this only makes the incoming context available.
Middleware<E> tracing<E>() => (Context<E> c, Handler<E> next) {
  final header = c.header('traceparent');
  if (header != null) {
    final trace = TraceContext.parse(header);
    if (trace != null) c.set(traceKey, trace);
  }
  return next(c);
};
