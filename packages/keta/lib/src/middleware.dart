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
          merged['vary'] = [...merged['vary']!, ...values];
        } else {
          merged[name] = values;
        }
      });
      if (allowed && exposeHeaders.isNotEmpty) {
        merged['access-control-expose-headers'] = [exposeHeaders.join(', ')];
      }
      return Response(r.status, headers: merged, body: r.body);
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
