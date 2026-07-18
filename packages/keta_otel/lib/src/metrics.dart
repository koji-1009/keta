library;

/// An in-process registry of request counts and duration histograms, keyed by
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
///
/// The duration family is a Prometheus *histogram*, not a summary — a prior
/// design emitted only `_sum`/`_count`, which cannot answer "what's p95
/// latency" (a summary's mean is derivable; a quantile is not, once the raw
/// samples are gone). A histogram instead buckets every observation as it
/// arrives, so `histogram_quantile` can estimate quantiles later from the
/// bucket counts, at the query engine, even after aggregating across series.
///
/// Each (method, route, status) key renders one cumulative
/// `_bucket{...,le="<edge>"}` line per entry in [buckets] (ascending, each
/// count including every observation `<=` that edge), one implicit
/// `_bucket{...,le="+Inf"}` line equal to `_count`, and the `_sum`/`_count`
/// pair — `buckets.length + 3` lines per key. Total exposition size for the
/// duration family is therefore bounded by (distinct method, route, status
/// combinations) × (`buckets.length + 3`); `keta_requests_total` adds one
/// more line per combination. Size [buckets] with that multiplier in mind —
/// a wider bucket list is a proportionally wider `/metrics` payload for
/// every route × method × status combination in play.
class MetricsRegistry {
  MetricsRegistry({List<double> buckets = defaultBuckets})
    : _buckets = _validateBuckets(buckets);

  /// Prometheus' own conventional bucket boundaries (seconds), covering 5ms
  /// to 10s on a roughly log scale — a reasonable default for in-process HTTP
  /// handler latencies. Pass `buckets:` to the constructor to replace them,
  /// e.g. to extend the range for handlers that call out to slow
  /// dependencies, or to narrow it for a tighter SLO.
  static const List<double> defaultBuckets = [
    .005,
    .01,
    .025,
    .05,
    .1,
    .25,
    .5,
    1,
    2.5,
    5,
    10,
  ];

  final List<double> _buckets;
  final Map<_Key, int> _count = {};
  // `double`, not `int`: most in-process handlers finish in well under a
  // millisecond, and truncating each sample to whole seconds before summing
  // would collapse essentially every sample to 0 rather than just losing
  // sub-unit precision on the total.
  final Map<_Key, double> _durationSecondsSum = {};
  // One counter per entry in [_buckets], indexed to match it. Each slot holds
  // only the observations that land in *that* bucket specifically (value <=
  // this edge and, implicitly, > every earlier edge) — not yet the cumulative
  // count the exposition format requires. `prometheus()` runs the cumulative
  // sum across slots, in ascending `le` order, at render time. An observation
  // greater than every configured edge increments no slot here: it is still
  // captured by `_count` (and so by the implicit `+Inf` bucket), just by no
  // finite one.
  final Map<_Key, List<int>> _bucketCounts = {};

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
    final counts = _bucketCounts.putIfAbsent(
      key,
      () => List.filled(_buckets.length, 0),
    );
    final index = _bucketIndexFor(durationSeconds);
    if (index != -1) {
      counts[index]++;
    }
  }

  /// The index of the first (smallest) configured edge `>= value` — `le` is
  /// "less than or equal", so a value exactly on an edge belongs to that
  /// edge's bucket, not the next one up. `-1` means `value` exceeds every
  /// configured edge (captured only by `_count`/`+Inf`, no finite bucket).
  int _bucketIndexFor(double value) {
    for (var i = 0; i < _buckets.length; i++) {
      if (value <= _buckets[i]) {
        return i;
      }
    }
    return -1;
  }

  /// The Prometheus text exposition of the collected series.
  ///
  /// Two metric families: `keta_requests_total` (a counter) and
  /// `keta_request_duration_seconds` (a *histogram* — see the class doc for
  /// why, and for the per-key line count).
  String prometheus() {
    final buffer = StringBuffer()
      ..writeln('# HELP keta_requests_total Total HTTP requests.')
      ..writeln('# TYPE keta_requests_total counter');
    _count.forEach((key, count) {
      buffer.writeln('keta_requests_total${key.labels()} $count');
    });
    buffer
      ..writeln(
        '# HELP keta_request_duration_seconds Request duration in seconds.',
      )
      ..writeln('# TYPE keta_request_duration_seconds histogram');
    _count.forEach((key, count) {
      final counts = _bucketCounts[key]!;
      var cumulative = 0;
      for (var i = 0; i < _buckets.length; i++) {
        cumulative += counts[i];
        buffer.writeln(
          'keta_request_duration_seconds_bucket'
          '${key.labels(le: _formatBucketEdge(_buckets[i]))} $cumulative',
        );
      }
      buffer.writeln(
        'keta_request_duration_seconds_bucket${key.labels(le: '+Inf')} '
        '$count',
      );
      buffer.writeln(
        'keta_request_duration_seconds_sum${key.labels()} '
        '${_durationSecondsSum[key]}',
      );
      buffer.writeln(
        'keta_request_duration_seconds_count${key.labels()} '
        '$count',
      );
    });
    return buffer.toString();
  }

  /// Validates a caller-supplied bucket list against the constraints the
  /// histogram exposition depends on, returning an unmodifiable copy.
  ///
  /// - Non-empty: a histogram with no buckets is just `_sum`/`_count`, i.e.
  ///   the summary this type no longer supports — construct one with at
  ///   least one boundary.
  /// - Strictly ascending: the cumulative-sum rendering in [prometheus] walks
  ///   `_buckets` once, front to back, assuming each edge is greater than the
  ///   last; a tie or a descending pair would silently misrender.
  /// - Finite and positive: `+Inf` is *implicit* — [prometheus] always
  ///   appends it — so an explicit infinite (or NaN, which is not finite
  ///   either) entry is rejected, and a zero or negative edge cannot bound a
  ///   non-negative duration.
  static List<double> _validateBuckets(List<double> buckets) {
    if (buckets.isEmpty) {
      throw ArgumentError.value(
        buckets,
        'buckets',
        'must not be empty (a histogram needs at least one boundary; +Inf '
            'is implicit and always added)',
      );
    }
    for (var i = 0; i < buckets.length; i++) {
      final edge = buckets[i];
      if (!edge.isFinite) {
        throw ArgumentError.value(
          buckets,
          'buckets',
          'must be finite — +Inf is implicit as the trailing bucket and '
              'must not be listed explicitly (index $i is $edge)',
        );
      }
      if (edge <= 0) {
        throw ArgumentError.value(
          buckets,
          'buckets',
          'must be positive (index $i is $edge)',
        );
      }
      if (i > 0 && buckets[i - 1] >= edge) {
        throw ArgumentError.value(
          buckets,
          'buckets',
          'must be strictly ascending (index ${i - 1} is ${buckets[i - 1]}, '
              'index $i is $edge)',
        );
      }
    }
    return List.unmodifiable(buckets);
  }
}

// Renders a bucket edge the way Prometheus's own default buckets are
// conventionally shown: a whole number has no trailing `.0` (`le="1"`, not
// `le="1.0"`), matching what a scraper and a human both expect to see next
// to `le="2.5"`. Dart's `double.toString()` always keeps a fractional part
// (`1.0.toString() == '1.0'`), so whole-valued edges are special-cased.
String _formatBucketEdge(double edge) {
  final truncated = edge.truncateToDouble();
  return truncated == edge ? truncated.toInt().toString() : edge.toString();
}

class _Key {
  const _Key(this.method, this.route, this.status);
  final String method;
  final String route;
  final int status;

  /// The label set for this key, `{method="...",route="...",status="..."}`.
  /// Pass [le] to append the histogram bucket-edge label used by
  /// `_bucket` lines (`+Inf` for the implicit trailing bucket).
  String labels({String? le}) {
    final base =
        'method="${_escape(method)}",route="${_escape(route)}",'
        'status="$status"';
    return le == null ? '{$base}' : '{$base,le="$le"}';
  }

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
