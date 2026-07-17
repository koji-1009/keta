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

/// The trace identity `otel()` established for the current request, exposed to
/// handlers under [otelSpanKey].
///
/// It carries the two ids a handler needs to correlate its own work with the
/// server span: the [traceId] — continued from an incoming `traceparent` or
/// freshly minted for a root request — and the [spanId] this middleware
/// generated for the span it records. A handler reads these to stamp the same
/// trace/span into its own log lines, or to build an outbound `traceparent`
/// (`00-$traceId-$spanId-01`) so a downstream service continues the trace.
///
/// This is keta_otel's counterpart to core's `tracing()`/`traceKey`, and the two
/// answer *different* questions. `tracing()` needs no otel dependency and
/// exposes the *incoming* context verbatim — the caller's ids from the
/// `traceparent` header, or nothing when there was none. [OtelSpanContext]
/// exposes the *current* span: the same traceId, but the span id minted here,
/// which no incoming header contains and which becomes the parent of anything
/// this request calls out to. Read `traceKey` for "who called me"; read
/// [otelSpanKey] for "what span am I".
class OtelSpanContext {
  const OtelSpanContext({required this.traceId, required this.spanId});

  /// The 32-hex trace id shared by every span in this trace.
  final String traceId;

  /// The 16-hex id of the span `otel()` recorded for this request.
  final String spanId;
}

/// The key under which [otel] exposes the current request's [OtelSpanContext].
/// See [OtelSpanContext] for how it relates to core's `traceKey`.
final Key<OtelSpanContext> otelSpanKey = Key<OtelSpanContext>('otel.span');

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
    // One traceparent parser for the whole stack: core's hardened
    // `TraceContext.parse` (keta is already a dependency), not a second copy
    // here. It rejects every malformed/uppercase/all-zero/reserved-version
    // header, so a garbage id can never reach `traceId` below and from there
    // an OTLP batch a collector would reject wholesale.
    final parent = incoming == null ? null : TraceContext.parse(incoming);
    // Honor the upstream sampling decision: a valid parent whose sampled bit
    // (traceparent flags bit 0) is clear means "not sampled", so this span is
    // not exported (metrics are recorded regardless). A root request defaults
    // to sampled. exportUnsampled overrides this to always export.
    final sampled =
        exportUnsampled || parent == null || (parent.flags & 0x01) != 0;
    final traceId = parent?.traceId ?? _hex(16);
    final spanId = _hex(8);
    // Expose this request's trace identity to handlers *before* the chain runs,
    // so a handler can read `c.get(otelSpanKey)` to log the ids or propagate
    // them outbound. This is the one place that knows both the (possibly
    // continued) traceId and the span id minted here; core's `tracing()` only
    // ever sees the incoming header, never this span.
    c.set(otelSpanKey, OtelSpanContext(traceId: traceId, spanId: spanId));

    void finish(int status) {
      watch.stop();
      final template = c.routeTemplate;
      final method = _foldMethod(c.method);
      metrics?.record(
        method: method,
        route: template ?? unmatchedRoute,
        status: status,
        // Seconds (Prometheus's base time unit), fractional: most in-process
        // handlers finish in well under a millisecond, so `elapsedMilliseconds`
        // would truncate to 0 for nearly every fast route and systematically
        // undercount the duration sum. `elapsedMicroseconds` carries the same
        // resolution the wall-clock span timestamps below use, divided down to
        // seconds so `keta_request_duration_seconds_sum` reads in base units.
        durationSeconds: watch.elapsedMicroseconds / 1e6,
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
        // Enqueued off the response hot path: this only appends to the
        // exporter's own bounded queue (see `OtlpExporter.enqueue`), never
        // sends synchronously. The exporter drains it on its own timer (or
        // `flush()`), so a failing collector — or a queue overflowing under
        // sustained load — is no longer tied to any one request's `Context`;
        // it is reported through the exporter's own `onWarn` hook (wired
        // once, when the exporter is constructed) instead of `c.log` here.
        export.enqueue([span]);
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
///
/// The content type is the Prometheus text exposition media type
/// (`text/plain; version=0.0.4; charset=utf-8`), not a bare `text/plain`: the
/// `version=0.0.4` parameter is how a scraper recognizes the format, and
/// omitting it leaves some scrapers guessing at the payload.
Handler<E> metricsHandler<E>(MetricsRegistry registry) =>
    (Context<E> c) => c.text(
      registry.prometheus(),
      headers: {
        'content-type': const ['text/plain; version=0.0.4; charset=utf-8'],
      },
    );

int _unixNano() => DateTime.now().microsecondsSinceEpoch * 1000;

String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
