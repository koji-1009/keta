import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

void main() {
  test('an empty registry renders only HELP and TYPE lines', () {
    expect(
      MetricsRegistry().prometheus(),
      '# HELP keta_requests_total Total HTTP requests.\n'
      '# TYPE keta_requests_total counter\n'
      '# HELP keta_request_duration_ms_sum Total request duration in milliseconds.\n'
      '# TYPE keta_request_duration_ms_sum counter\n',
    );
  });

  test('label values escape backslash, quote, and newline', () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/a"b\\c\nd', status: 200, durationMs: 1);
    expect(registry.prometheus(), contains(r'route="/a\"b\\c\nd"'));
  });

  test('identical keys aggregate; any differing field is a separate series',
      () {
    final registry = MetricsRegistry()
      ..record(method: 'GET', route: '/x', status: 200, durationMs: 5)
      ..record(method: 'GET', route: '/x', status: 200, durationMs: 7)
      ..record(method: 'POST', route: '/x', status: 200, durationMs: 1)
      ..record(method: 'GET', route: '/y', status: 200, durationMs: 1)
      ..record(method: 'GET', route: '/x', status: 500, durationMs: 1);
    final body = registry.prometheus();

    expect(body,
        contains('keta_requests_total{method="GET",route="/x",status="200"} 2'));
    expect(
        body,
        contains(
            'keta_request_duration_ms_sum{method="GET",route="/x",status="200"} 12'));
    expect(body, contains('{method="POST",route="/x",status="200"} 1'));
    expect(body, contains('{method="GET",route="/y",status="200"} 1'));
    expect(body, contains('{method="GET",route="/x",status="500"} 1'));
  });
}
