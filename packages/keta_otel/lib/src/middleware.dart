library;

import 'dart:math';

import 'package:keta/keta.dart';

import 'metrics.dart';
import 'otlp.dart';
import 'span.dart';

final Random _random = Random.secure();

/// The known keta HTTP verbs (the closed set `App`'s DSL binds — see
/// `packages/keta/lib/src/app.dart`). Matched case-insensitively against the
/// incoming request line and normalized to uppercase; anything else folds to
/// [_unknownMethod].
const Set<String> _knownMethods = {
  'GET',
  'POST',
  'PUT',
  'DELETE',
  'PATCH',
  'HEAD',
  'OPTIONS',
};

/// The label recorded for the method dimension (metrics), folded into the
/// span name and `http.request.method` attribute (traces), when a request's
/// method is not one of the seven keta verbs.
///
/// The HTTP request line accepts any token as a method — attacker-controlled
/// and unbounded, exactly like an unmatched path. Recording it verbatim would
/// mint a permanent metrics series and a method-bearing span name per bogus
/// method a client sends. This fixed label keeps the method dimension bounded
/// regardless of what a client sends.
const String _unknownMethod = '(other)';

/// Folds [method] to one of the known keta verbs (uppercased), or
/// [_unknownMethod] if it matches none. Keeps the method axis bounded on
/// both the metrics registry and the exported span (name + attributes).
String _foldMethod(String method) {
  final upper = method.toUpperCase();
  return _knownMethods.contains(upper) ? upper : _unknownMethod;
}

/// Records one server span per request and, optionally, request metrics.
///
/// The span continues an incoming `traceparent` when present (otherwise it
/// starts a new trace) and is named `METHOD /route/template` for low
/// cardinality. A request that matches no route is named just `METHOD`
/// (OTel semconv: an unmatched-route SERVER span omits `http.route` and
/// drops the path from the name), and its metrics record under
/// `unmatchedRoute` rather than the raw, attacker-controlled path. `METHOD`
/// itself is folded to one of the seven known keta verbs (uppercased) or
/// [_unknownMethod] — the HTTP request line accepts any token, so an
/// unrecognized method is bounded the same way an unmatched route is. Export
/// and metric recording happen after the response is produced and never
/// block or fail the request.
///
/// The upstream sampled flag is honored by default: an incoming traceparent
/// with the sampled bit clear is not exported. Pass [exportUnsampled] `true` to
/// export every request's span regardless of the upstream decision.
Middleware<E> otel<E>({
  OtlpExporter? exporter,
  MetricsRegistry? metrics,
  bool exportUnsampled = false,
}) {
  return (Context<E> c, Handler<E> next) {
    final startNano = _unixNano();
    final watch = Stopwatch()..start();
    final incoming = c.header('traceparent');
    final parent = incoming == null ? null : TraceContext.parse(incoming);
    // Honor the upstream sampling decision: a valid parent whose sampled bit
    // (traceparent flags bit 0) is clear means "not sampled", so this span is
    // not exported (metrics are recorded regardless). A root request defaults
    // to sampled. exportUnsampled overrides this to always export.
    final sampled =
        exportUnsampled || parent == null || (parent.flags & 0x01) != 0;
    final traceId = parent?.traceId ?? _hex(16);
    final spanId = _hex(8);

    void finish(int status) {
      watch.stop();
      final template = c.routeTemplate;
      final method = _foldMethod(c.method);
      metrics?.record(
        method: method,
        route: template ?? unmatchedRoute,
        status: status,
        durationMs: watch.elapsedMilliseconds,
      );
      final export = exporter;
      if (export != null && sampled) {
        final span = OtelSpan(
          traceId: traceId,
          spanId: spanId,
          parentSpanId: parent?.parentId,
          name: template == null ? method : '$method $template',
          startUnixNano: startNano,
          endUnixNano: _unixNano(),
          attributes: {
            'http.request.method': method,
            'http.route': ?template,
            'http.response.status_code': status,
          },
          // OTel SERVER-span convention: Error only for 5xx; otherwise Unset
          // (a 4xx is a client problem, not a server error).
          status: status >= 500 ? SpanStatus.error : SpanStatus.unset,
        );
        // Enqueued off the response hot path; a failing collector is logged
        // (not silently dropped) and never fails the request.
        export.enqueue(
          [span],
          onError: (error, _) =>
              c.log.warn('span export failed', {'error': '$error'}),
        );
      }
    }

    return guard<Response>(
      () => chain(next(c), (Response r) {
        finish(r.status);
        return r;
      }),
      (error, st) {
        finish(error is KetaException ? error.status : 500);
        Error.throwWithStackTrace(error, st);
      },
    );
  };
}

/// A handler that renders [registry] in Prometheus text format. Mount it at
/// `/metrics`.
Handler<E> metricsHandler<E>(MetricsRegistry registry) =>
    (Context<E> c) => c.text(registry.prometheus());

int _unixNano() => DateTime.now().microsecondsSinceEpoch * 1000;

String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
