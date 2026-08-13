library;

/// OTLP status codes: unset, ok, error.
enum SpanStatus { unset, ok, error }

/// A finished server span for one request.
class const OtelSpan({
  required final String traceId, // 32 hex chars
  required final String spanId, // 16 hex chars
  final String? parentSpanId, // 16 hex chars, or null for a root
  required final String name,
  required final int startUnixNano,
  required final int endUnixNano,
  final Map<String, Object?> attributes = const {},
  final SpanStatus status = SpanStatus.unset,
});
