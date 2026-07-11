library;

/// OTLP status codes: unset, ok, error.
enum SpanStatus { unset, ok, error }

/// A finished server span for one request.
class OtelSpan {
  final String traceId; // 32 hex chars
  final String spanId; // 16 hex chars
  final String? parentSpanId; // 16 hex chars, or null for a root
  final String name;
  final int startUnixNano;
  final int endUnixNano;
  final Map<String, Object?> attributes;
  final SpanStatus status;

  const OtelSpan({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    required this.name,
    required this.startUnixNano,
    required this.endUnixNano,
    this.attributes = const {},
    this.status = SpanStatus.unset,
  });
}
