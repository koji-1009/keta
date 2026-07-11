import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

class Env {}

void main() {
  test('otel records a server span continuing the incoming traceparent',
      () async {
    final captured = <String>[];
    final exporter = OtlpExporter((payload) async => captured.add(payload));
    final app = App<Env>()..use(otel(exporter: exporter));
    app.get('/users/:id', (c) => c.json({'id': c.param<String>('id')}));
    final client = TestClient(app, Env());

    await client.get('/users/7', headers: {
      'traceparent':
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
    });

    expect(captured, hasLength(1));
    final span = jsonDecode(captured.single)['resourceSpans'][0]['scopeSpans']
        [0]['spans'][0] as Map<String, Object?>;
    expect(span['name'], 'GET /users/:id');
    expect(span['traceId'], '0af7651916cd43dd8448eb211c80319c');
    expect(span['parentSpanId'], 'b7ad6b7169203331');
    expect((span['status'] as Map)['code'], SpanStatus.ok.index);
  });

  test('a 5xx span is marked error', () async {
    final captured = <String>[];
    final exporter = OtlpExporter((payload) async => captured.add(payload));
    final app = App<Env>()..use(otel(exporter: exporter));
    app.get('/boom', (c) => throw StateError('x'));
    final client = TestClient(app, Env());

    await client.get('/boom');
    final span = jsonDecode(captured.single)['resourceSpans'][0]['scopeSpans']
        [0]['spans'][0] as Map<String, Object?>;
    expect((span['status'] as Map)['code'], SpanStatus.error.index);
  });

  test('metrics accumulate and render at /metrics', () async {
    final metrics = MetricsRegistry();
    final app = App<Env>()..use(otel(metrics: metrics));
    app.get('/users/:id', (c) => c.text('ok'));
    app.get('/metrics', metricsHandler(metrics));
    final client = TestClient(app, Env());

    await client.get('/users/1');
    await client.get('/users/2');
    final body = (await client.get('/metrics')).text();

    expect(
      body,
      contains('keta_requests_total{method="GET",route="/users/:id",status="200"} 2'),
    );
    expect(body, contains('keta_request_duration_ms_sum{method="GET"'));
  });

  test('encodeOtlp carries the service name', () {
    final doc = encodeOtlp(
      [
        OtelSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'GET /x',
          startUnixNano: 1,
          endUnixNano: 2,
        ),
      ],
      'svc',
    );
    final resource = (doc['resourceSpans'] as List)[0]['resource'] as Map;
    expect((resource['attributes'] as List)[0]['value']['stringValue'], 'svc');
  });
}
