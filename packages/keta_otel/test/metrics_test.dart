/// `MetricsRegistry`'s Prometheus text exposition: label escaping, the
/// duration histogram's exposition shape (buckets/le/+Inf/_sum/_count),
/// cumulative monotonicity, boundary placement, and custom-bucket
/// validation.
library;

import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

void main() {
  test('an empty registry renders only HELP and TYPE lines', () {
    expect(
      MetricsRegistry().prometheus(),
      '# HELP keta_requests_total Total HTTP requests.\n'
      '# TYPE keta_requests_total counter\n'
      '# HELP keta_request_duration_seconds Request duration in seconds.\n'
      '# TYPE keta_request_duration_seconds histogram\n',
    );
  });

  test('the duration family is declared a histogram, never a summary', () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 1);
    final body = registry.prometheus();
    expect(body, contains('# TYPE keta_request_duration_seconds histogram'));
    // The summary form this replaces is gone outright, not kept alongside:
    // no "summary" anywhere, and no bare (non-`_bucket`/`_sum`/`_count`)
    // duration line.
    expect(body, isNot(contains('summary')));
  });

  test('label values escape backslash, quote, and newline', () {
    final registry = MetricsRegistry()
      ..record(
        method: 'GET',
        route: '/a"b\\c\nd',
        status: 200,
        durationSeconds: 1,
      );
    final body = registry.prometheus();
    expect(body, contains(r'route="/a\"b\\c\nd"'));
    // The escaping applies identically on bucket lines, which carry the
    // extra `le` label.
    expect(body, contains(r'route="/a\"b\\c\nd",status="200",le="1"} 1'));
  });

  test('a carriage return in a label value round-trips escaped, not raw', () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/a\rb', status: 200, durationSeconds: 1);
    final body = registry.prometheus();
    // The CR is emitted as the two-character escape `\r`, never as a raw
    // carriage return that a CRLF-framed scraper could desync on.
    expect(body, contains(r'route="/a\rb"'));
    expect(body, isNot(contains('\r')));
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

  test('the duration histogram emits a _count equal to the request total', () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.5)
      ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.25);
    final body = registry.prometheus();
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
    // The implicit +Inf bucket always equals _count: every observation is
    // <= +Inf, by definition.
    expect(
      body,
      contains(
        'keta_request_duration_seconds_bucket'
        '{method="GET",route="/x",status="200",le="+Inf"} 2',
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

  group('histogram exposition shape', () {
    test('default buckets render the Prometheus-conventional le series in '
        'ascending order, whole numbers unpadded', () {
      final registry = MetricsRegistry()
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0);
      final body = registry.prometheus();
      final leValues = RegExp(
        r'keta_request_duration_seconds_bucket\{[^}]*le="([^"]+)"\}',
      ).allMatches(body).map((m) => m.group(1)!).toList();
      expect(leValues, [
        '0.005',
        '0.01',
        '0.025',
        '0.05',
        '0.1',
        '0.25',
        '0.5',
        '1', // not "1.0"
        '2.5',
        '5', // not "5.0"
        '10', // not "10.0"
        '+Inf',
      ]);
      expect(MetricsRegistry.defaultBuckets, hasLength(11));
    });

    test('a single key renders exactly buckets.length + 3 duration lines', () {
      final registry = MetricsRegistry()
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 1);
      final durationLines = registry
          .prometheus()
          .split('\n')
          .where((l) => l.startsWith('keta_request_duration_seconds_'))
          .toList();
      expect(
        durationLines,
        hasLength(MetricsRegistry.defaultBuckets.length + 3),
      );
    });

    test('cumulative counts never decrease as le increases, and the final '
        'finite bucket does not exceed +Inf/_count', () {
      final registry = MetricsRegistry()
        ..record(
          method: 'GET',
          route: '/x',
          status: 200,
          durationSeconds: 0.001,
        )
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.2)
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 3)
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 50);
      final body = registry.prometheus();
      final counts = RegExp(
        r'keta_request_duration_seconds_bucket\{[^}]*le="[^"]+"\} (\d+)',
      ).allMatches(body).map((m) => int.parse(m.group(1)!)).toList();

      for (var i = 1; i < counts.length; i++) {
        expect(
          counts[i],
          greaterThanOrEqualTo(counts[i - 1]),
          reason:
              'bucket $i (${counts[i]}) < bucket ${i - 1} '
              '(${counts[i - 1]})',
        );
      }
      // The last entry is the +Inf bucket, which must equal _count (4
      // observations were recorded, one — 50s — beyond every finite edge).
      expect(counts.last, 4);
      expect(
        body,
        contains(
          'keta_request_duration_seconds_count'
          '{method="GET",route="/x",status="200"} 4',
        ),
      );
    });

    test('an observation past every finite bucket only reaches +Inf, no finite '
        'bucket', () {
      final registry = MetricsRegistry(buckets: [0.1, 0.2])
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 5);
      final body = registry.prometheus();
      const key = '{method="GET",route="/x",status="200"';
      expect(body, contains('$key,le="0.1"} 0'));
      expect(body, contains('$key,le="0.2"} 0'));
      expect(body, contains('$key,le="+Inf"} 1'));
    });

    test('a boundary observation exactly on a bucket edge lands in that bucket '
        '(le is <=, not <)', () {
      final registry = MetricsRegistry(buckets: [0.1, 0.2, 0.3])
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 0.2);
      final body = registry.prometheus();
      const key = '{method="GET",route="/x",status="200"';
      // Below the edge it lands on: not yet counted.
      expect(body, contains('$key,le="0.1"} 0'));
      // Exactly on the edge: counted here, per <=.
      expect(body, contains('$key,le="0.2"} 1'));
      // Every higher edge is cumulative, so it carries forward too.
      expect(body, contains('$key,le="0.3"} 1'));
      expect(body, contains('$key,le="+Inf"} 1'));
    });

    test('custom buckets fully replace the defaults, not extend them', () {
      final registry = MetricsRegistry(buckets: [1, 2])
        ..record(method: 'GET', route: '/x', status: 200, durationSeconds: 1);
      final body = registry.prometheus();
      expect(body, isNot(contains('le="0.005"')));
      expect(body, isNot(contains('le="10"')));
      final durationLines = body
          .split('\n')
          .where((l) => l.startsWith('keta_request_duration_seconds_'))
          .toList();
      // 2 finite buckets + 1 (+Inf) + _sum + _count.
      expect(durationLines, hasLength(5));
    });
  });

  group('bucket validation', () {
    test('an empty bucket list is rejected', () {
      expect(
        () => MetricsRegistry(buckets: const []),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('not be empty'),
          ),
        ),
      );
    });

    test('a non-ascending bucket list is rejected', () {
      expect(
        () => MetricsRegistry(buckets: const [0.5, 0.5]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('ascending'),
          ),
        ),
      );
      expect(
        () => MetricsRegistry(buckets: const [0.5, 0.1]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('ascending'),
          ),
        ),
      );
    });

    test('a zero or negative bucket edge is rejected', () {
      expect(
        () => MetricsRegistry(buckets: const [0]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('positive'),
          ),
        ),
      );
      expect(
        () => MetricsRegistry(buckets: const [-1, 1]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('positive'),
          ),
        ),
      );
    });

    test(
      'an explicit +Inf bucket is rejected — the +Inf bucket is implicit',
      () {
        expect(
          () => MetricsRegistry(buckets: [1, double.infinity]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('implicit'),
            ),
          ),
        );
      },
    );

    test('NaN is rejected as not finite', () {
      expect(() => MetricsRegistry(buckets: [double.nan]), throwsArgumentError);
    });
  });
}
