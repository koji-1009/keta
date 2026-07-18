library;

/// An in-process registry of request counts and total durations, keyed by
/// method, route template, and status, rendered in Prometheus text format.
///
/// Cardinality is unbounded by design: every distinct (method, route, status)
/// is a permanent series with no cap or eviction. This is safe only because
/// both `method` and `route` are bounded before they reach [record]: `route`
/// is the low-cardinality route *template* (`/users/:id`, not `/users/42`,
/// and a fixed label when unmatched), and `method` is folded to the closed
/// set of keta verbs (a fixed label when not one of them) — see
/// `middleware.dart`'s `otel()`. Do not `record` with a high-cardinality or
/// attacker-controlled method or route — either grows memory without bound.
class MetricsRegistry {
  final Map<_Key, int> _count = {};
  // `double`, not `int`: most in-process handlers finish in well under a
  // millisecond, and truncating each sample to whole seconds before summing
  // would collapse essentially every sample to 0 rather than just losing
  // sub-unit precision on the total.
  final Map<_Key, double> _durationSecondsSum = {};

  void record({
    required String method,
    required String route,
    required int status,
    required double durationSeconds,
  }) {
    final key = _Key(method, route, status);
    _count.update(key, (v) => v + 1, ifAbsent: () => 1);
    _durationSecondsSum.update(
      key,
      (v) => v + durationSeconds,
      ifAbsent: () => durationSeconds,
    );
  }

  /// The Prometheus text exposition of the collected series.
  ///
  /// Two metric families: `keta_requests_total` (a counter) and
  /// `keta_request_duration_seconds` (a *summary*). The duration was previously
  /// mis-declared `# TYPE ... counter` on a `_sum`-suffixed, millisecond name —
  /// two conformance lies at once: `_sum`/`_count` are the reserved suffixes of
  /// the summary family (never a counter's), and Prometheus convention wants the
  /// base time unit, seconds. Declaring it a `summary` and emitting the
  /// `_sum`/`_count` pair in seconds is the conforming shape; a dashboard reads
  /// mean latency as `rate(..._sum) / rate(..._count)` with no unit fixups.
  ///
  /// The summary's `_count` necessarily equals `keta_requests_total` (both count
  /// requests per series); a summary is required to carry its own `_count`, and
  /// a scraper reads the two names as independent series, so emitting both is
  /// correct, not redundant.
  String prometheus() {
    final buffer = StringBuffer()
      ..writeln('# HELP keta_requests_total Total HTTP requests.')
      ..writeln('# TYPE keta_requests_total counter');
    _count.forEach((key, count) {
      buffer.writeln('keta_requests_total${key.labels} $count');
    });
    buffer
      ..writeln(
        '# HELP keta_request_duration_seconds Request duration in seconds.',
      )
      ..writeln('# TYPE keta_request_duration_seconds summary');
    _durationSecondsSum.forEach((key, sum) {
      buffer.writeln('keta_request_duration_seconds_sum${key.labels} $sum');
    });
    _count.forEach((key, count) {
      buffer.writeln('keta_request_duration_seconds_count${key.labels} $count');
    });
    return buffer.toString();
  }
}

class _Key {
  const _Key(this.method, this.route, this.status);
  final String method;
  final String route;
  final int status;

  String get labels =>
      '{method="${_escape(method)}",route="${_escape(route)}",status="$status"}';

  @override
  bool operator ==(Object other) =>
      other is _Key &&
      other.method == method &&
      other.route == route &&
      other.status == status;

  @override
  int get hashCode => Object.hash(method, route, status);
}

// Prometheus label values are a backslash-escaped, double-quoted string on a
// single text-exposition line, so the three characters that would otherwise
// break that framing — `\` (the escape char itself, first so it never
// double-escapes the sequences added below), `"` (the delimiter), and `\n`
// (the line terminator) — are escaped. `\r` gets the same treatment: a bare
// carriage return is not a line terminator Prometheus recognizes, but a
// scraper reading the exposition over a CRLF transport can still be desynced
// by a raw CR inside a value, so it is escaped rather than emitted literally.
String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');
