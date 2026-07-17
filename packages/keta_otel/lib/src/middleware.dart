library;

import 'dart:math';

import 'package:keta/keta.dart';

import 'metrics.dart';
import 'otlp.dart';
import 'span.dart';

final Random _random = Random.secure();

/// The label recorded for the route dimension (metrics) and folded into the
/// span name (traces) when a request matches no route.
///
/// App-level middleware wraps unmatched requests too (404/405), and for those
/// `c.route` falls back to the raw request path — attacker-controlled and
/// unbounded. Recording it would mint a permanent metrics series and a
/// path-bearing span name per distinct path an attacker probes. This fixed
/// label keeps the route dimension bounded regardless of what a client sends.
const String _unmatchedRoute = '(unmatched)';

/// Records one server span per request and, optionally, request metrics.
///
/// The span continues an incoming `traceparent` when present (otherwise it
/// starts a new trace) and is named `METHOD /route/template` for low
/// cardinality. A request that matches no route is named just `METHOD`
/// (OTel semconv: an unmatched-route SERVER span omits `http.route` and
/// drops the path from the name), and its metrics record under
/// [_unmatchedRoute] rather than the raw, attacker-controlled path. Export
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
      metrics?.record(
        method: c.method,
        route: template ?? _unmatchedRoute,
        status: status,
        durationMs: watch.elapsedMilliseconds,
      );
      final export = exporter;
      if (export != null && sampled) {
        final span = OtelSpan(
          traceId: traceId,
          spanId: spanId,
          parentSpanId: parent?.parentId,
          name: template == null ? c.method : '${c.method} $template',
          startUnixNano: startNano,
          endUnixNano: _unixNano(),
          attributes: {
            'http.request.method': c.method,
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
