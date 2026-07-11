library;

import 'dart:math';

import 'package:keta/keta.dart';

import 'metrics.dart';
import 'otlp.dart';
import 'span.dart';

final Random _random = Random.secure();

/// Records one server span per request and, optionally, request metrics.
///
/// The span continues an incoming `traceparent` when present (otherwise it
/// starts a new trace) and is named `METHOD /route/template` for low
/// cardinality. Export and metric recording happen after the response is
/// produced and never block or fail the request.
Middleware<E> otel<E>({OtlpExporter? exporter, MetricsRegistry? metrics}) {
  return (Context<E> c, Handler<E> next) {
    final startNano = _unixNano();
    final watch = Stopwatch()..start();
    final incoming = c.header('traceparent');
    final parent = incoming == null ? null : TraceContext.parse(incoming);
    final traceId = parent?.traceId ?? _hex(16);
    final spanId = _hex(8);

    void finish(int status) {
      watch.stop();
      metrics?.record(
        method: c.method,
        route: c.route,
        status: status,
        durationMs: watch.elapsedMilliseconds,
      );
      exporter
          ?.export([
            OtelSpan(
              traceId: traceId,
              spanId: spanId,
              parentSpanId: parent?.parentId,
              name: '${c.method} ${c.route}',
              startUnixNano: startNano,
              endUnixNano: _unixNano(),
              attributes: {
                'http.request.method': c.method,
                'http.route': c.route,
                'http.response.status_code': status,
              },
              status: status >= 500 ? SpanStatus.error : SpanStatus.ok,
            ),
          ])
          .catchError((Object _) {});
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
