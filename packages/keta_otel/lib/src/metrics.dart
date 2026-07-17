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
  // millisecond, and truncating each sample to whole milliseconds before
  // summing systematically undercounts (often to exactly 0) rather than
  // just losing sub-ms precision on the total.
  final Map<_Key, double> _durationMsSum = {};

  void record({
    required String method,
    required String route,
    required int status,
    required double durationMs,
  }) {
    final key = _Key(method, route, status);
    _count.update(key, (v) => v + 1, ifAbsent: () => 1);
    _durationMsSum.update(
      key,
      (v) => v + durationMs,
      ifAbsent: () => durationMs,
    );
  }

  /// The Prometheus text exposition of the collected series.
  String prometheus() {
    final buffer = StringBuffer()
      ..writeln('# HELP keta_requests_total Total HTTP requests.')
      ..writeln('# TYPE keta_requests_total counter');
    _count.forEach((key, count) {
      buffer.writeln('keta_requests_total${key.labels} $count');
    });
    buffer
      ..writeln(
        '# HELP keta_request_duration_ms_sum '
        'Total request duration in milliseconds.',
      )
      ..writeln('# TYPE keta_request_duration_ms_sum counter');
    _durationMsSum.forEach((key, sum) {
      buffer.writeln('keta_request_duration_ms_sum${key.labels} $sum');
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

String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n');
