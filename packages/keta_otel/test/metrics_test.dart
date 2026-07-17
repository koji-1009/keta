import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

void main() {
  // Updated for the Prometheus-conformance rename: the duration family is now
  // `keta_request_duration_seconds`, declared `# TYPE ... summary` (was a
  // `_sum`-suffixed, millisecond name mis-typed `counter`), and it emits the
  // reserved summary pair `_sum` + `_count`.
  test('an empty registry renders only HELP and TYPE lines', () {
    expect(
      MetricsRegistry().prometheus(),
      '# HELP keta_requests_total Total HTTP requests.\n'
      '# TYPE keta_requests_total counter\n'
      '# HELP keta_request_duration_seconds Request duration in seconds.\n'
      '# TYPE keta_request_duration_seconds summary\n',
    );
  });

  test('label values escape backslash, quote, and newline', () {
    final registry = MetricsRegistry()
      ..record(
        method: 'GET',
        route: '/a"b\\c\nd',
        status: 200,
        durationSeconds: 1,
      );
    expect(registry.prometheus(), contains(r'route="/a\"b\\c\nd"'));
  });

  test(
    'fractional durations accumulate exactly, not truncated to whole units',
    () {
      // 0.5 and 0.25 are exact binary fractions, so this sum is exact —
      // no floating-point noise to account for in the assertion. Before the
      // precision fix, `middleware.dart` passed an int duration, which would
      // have truncated sub-unit samples like these to 0.
      final registry = MetricsRegistry()
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.5)
        ..record(
          method: 'GET',
          route: '/x',
          status: 200,
          durationSeconds: 0.25,
        );
      expect(
        registry.prometheus(),
        contains(
          'keta_request_duration_seconds_sum'
          '{method="GET",route="/x",status="200"} 0.75',
        ),
      );
    },
  );

  test('the duration summary emits a _count equal to the request total', () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.5)
      ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.25);
    final body = registry.prometheus();
    // The summary's own `_count` mirrors `keta_requests_total` for the same
    // series — both count requests, and a summary must carry its own count.
    expect(
      body,
      contains('keta_requests_total{method="GET",route="/x",status="200"} 2'),
    );
    expect(
      body,
      contains(
        'keta_request_duration_seconds_count'
        '{method="GET",route="/x",status="200"} 2',
      ),
    );
  });

  test(
    'identical keys aggregate; any differing field is a separate series',
    () {
      final registry = MetricsRegistry()
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 5)
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 7)
        ..record(method: 'POST', route: '/x', status: 200, durationSeconds: 1)
        ..record(method: 'GET', route: '/y', status: 200, durationSeconds: 1)
        ..record(method: 'GET', route: '/x', status: 500, durationSeconds: 1);
      final body = registry.prometheus();

      expect(
        body,
        contains('keta_requests_total{method="GET",route="/x",status="200"} 2'),
      );
      expect(
        body,
        contains(
          'keta_request_duration_seconds_sum'
          '{method="GET",route="/x",status="200"} 12',
        ),
      );
      expect(body, contains('{method="POST",route="/x",status="200"} 1'));
      expect(body, contains('{method="GET",route="/y",status="200"} 1'));
      expect(body, contains('{method="GET",route="/x",status="500"} 1'));
    },
  );
}
