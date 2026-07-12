library;

import 'dart:async';

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
      return Response.json({'error': error.message}, error.status);
    }
    c.log.error('unhandled exception', error, st);
    return Response(500, body: '');
  });
};

/// Attaches CORS headers and answers preflight `OPTIONS` requests. Stateless
/// and pure: an origin is allowed when it is listed or [allowOrigins] contains
/// `'*'`.
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
}) {
  final origins = allowOrigins.toSet();
  final wildcard = origins.contains('*');
  return (Context<E> c, Handler<E> next) {
    final origin = c.header('origin');
    final allowed = wildcard || (origin != null && origins.contains(origin));
    final corsHeaders = <String, String>{
      if (allowed) ...{
        'access-control-allow-origin': wildcard ? '*' : origin!,
        'access-control-allow-methods': allowMethods.join(', '),
        'access-control-allow-headers': allowHeaders.join(', '),
      },
    };
    if (c.method == 'OPTIONS') {
      return Response(204, headers: corsHeaders);
    }
    return chain(
      next(c),
      (Response r) => Response(
        r.status,
        headers: {...r.headers, ...corsHeaders},
        body: r.body,
      ),
    );
  };
}

/// Fails a request that outlives [d] with `KetaException(504)` and completes
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
      const KetaException(504, 'request timeout'),
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

/// A parsed W3C `traceparent` header.
class TraceContext {
  const TraceContext(this.traceId, this.parentId, this.flags);
  final String traceId;
  final String parentId;
  final int flags;

  /// Parses `version-traceId-parentId-flags`, returning null if malformed.
  static TraceContext? parse(String header) {
    final parts = header.split('-');
    if (parts.length != 4) return null;
    final traceId = parts[1];
    final parentId = parts[2];
    if (traceId.length != 32 || parentId.length != 16) return null;
    final flags = int.tryParse(parts[3], radix: 16);
    if (flags == null) return null;
    return TraceContext(traceId, parentId, flags);
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
