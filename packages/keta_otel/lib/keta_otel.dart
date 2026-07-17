/// keta_otel — request spans over a minimal OTLP/HTTP JSON exporter and a
/// Prometheus /metrics endpoint, with no external OpenTelemetry SDK.
library;

export 'src/metrics.dart' show MetricsRegistry;
export 'src/middleware.dart'
    show otel, metricsHandler, OtelSpanContext, otelSpanKey;
export 'src/otlp.dart' show OtlpExporter, OtlpSender, OtlpWarn, encodeOtlp;
export 'src/span.dart' show OtelSpan, SpanStatus;
