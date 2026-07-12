import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

class Env {}

/// An in-memory log for asserting on middleware output.
class MemLog implements Log {
  MemLog(this.lines) : _baked = const {};
  MemLog._(this.lines, this._baked);
  final List<Map<String, Object?>> lines;
  final Map<String, Object?> _baked;
  void _add(String level, String msg, Map<String, Object?> fields) =>
      lines.add({'level': level, 'msg': msg, ..._baked, ...fields});
  @override
  void debug(String msg, [Map<String, Object?> f = const {}]) =>
      _add('debug', msg, f);
  @override
  void info(String msg, [Map<String, Object?> f = const {}]) =>
      _add('info', msg, f);
  @override
  void warn(String msg, [Map<String, Object?> f = const {}]) =>
      _add('warn', msg, f);
  @override
  void error(
    String msg, [
    Object? e,
    StackTrace? st,
    Map<String, Object?> f = const {},
  ]) => _add('error', msg, {...f, if (e != null) 'error': '$e'});
  @override
  Future<void> flush() async {}
  @override
  Log withFields(Map<String, Object?> f) => MemLog._(lines, {..._baked, ...f});
}

class LogEnv implements HasLog {
  LogEnv(this.log);
  @override
  final Log log;
}

Map<String, Object?> _spanIn(Map<String, Object?> doc) {
  final rs = (doc['resourceSpans'] as List).first as Map<String, Object?>;
  final ss = (rs['scopeSpans'] as List).first as Map<String, Object?>;
  return (ss['spans'] as List).first as Map<String, Object?>;
}

Map<String, Object?> _spanOf(String payload) =>
    _spanIn(jsonDecode(payload) as Map<String, Object?>);

Map<String, Object?> _firstSpan(List<String> captured) =>
    _spanOf(captured.single);

Map<String, Object?> _attrsOf(Map<String, Object?> span) => {
  for (final a in span['attributes'] as List)
    (a as Map)['key'] as String: (a['value'] as Map).cast<String, Object?>(),
};

void main() {
  test(
    'otel records a server span continuing the incoming traceparent',
    () async {
      final captured = <String>[];
      final exporter = OtlpExporter((payload) async => captured.add(payload));
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/users/:id', (c) => c.json({'id': c.param<String>('id')}));
      final client = TestClient(app, Env());

      await client.get(
        '/users/7',
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        },
      );
      await pumpEventQueue(); // export is deferred off the hot path

      expect(captured, hasLength(1));
      final span = _firstSpan(captured);
      expect(span['name'], 'GET /users/:id');
      expect(span['traceId'], '0af7651916cd43dd8448eb211c80319c');
      expect(span['parentSpanId'], 'b7ad6b7169203331');
      // OTel SERVER convention: a 2xx leaves status unset (not ok).
      expect((span['status'] as Map)['code'], SpanStatus.unset.index);
    },
  );

  test('a 5xx span is marked error', () async {
    final captured = <String>[];
    final exporter = OtlpExporter((payload) async => captured.add(payload));
    final app = App<Env>()..use(otel(exporter: exporter));
    app.get('/boom', (c) => throw StateError('x'));
    final client = TestClient(app, Env());

    await client.get('/boom');
    await pumpEventQueue();
    final span = _firstSpan(captured);
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
      contains(
        'keta_requests_total{method="GET",route="/users/:id",status="200"} 2',
      ),
    );
    expect(body, contains('keta_request_duration_ms_sum{method="GET"'));
  });

  test('encodeOtlp carries the service name', () {
    final doc = encodeOtlp([
      OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      ),
    ], 'svc');
    final resource =
        ((doc['resourceSpans'] as List).first
                as Map<String, Object?>)['resource']
            as Map<String, Object?>;
    final attr = (resource['attributes'] as List).first as Map<String, Object?>;
    expect((attr['value'] as Map)['stringValue'], 'svc');
  });

  group('trace context', () {
    test('no traceparent starts a new root trace', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      await pumpEventQueue();

      final span = _firstSpan(captured);
      expect(span['traceId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(span['spanId'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(span.containsKey('parentSpanId'), isFalse);
    });

    for (final bad in [
      'garbage',
      '00-abc-b7ad6b7169203331-01',
      '00-0af7651916cd43dd8448eb211c80319c-abc-01',
      '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-zz',
    ]) {
      test(
        'a malformed traceparent "$bad" falls back to a new trace',
        () async {
          final captured = <String>[];
          final app = App<Env>()
            ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
          app.get('/x', (c) => c.text('ok'));
          await TestClient(app, Env()).get('/x', headers: {'traceparent': bad});
          await pumpEventQueue();

          final span = _firstSpan(captured);
          expect(span['traceId'], matches(RegExp(r'^[0-9a-f]{32}$')));
          expect(span['traceId'], isNot('0af7651916cd43dd8448eb211c80319c'));
          expect(span.containsKey('parentSpanId'), isFalse);
        },
      );
    }
  });

  group('span status', () {
    test('a thrown KetaException(404) yields a 4xx unset span', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/missing', (c) => throw const KetaException(404, 'nope'));
      final res = await TestClient(app, Env()).get('/missing');
      await pumpEventQueue();

      expect(res.status, 404);
      final span = _firstSpan(captured);
      expect((span['status'] as Map)['code'], SpanStatus.unset.index);
      expect(_attrsOf(span)['http.response.status_code'], {'intValue': '404'});
    });

    test('a thrown KetaException(503) yields an error span', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/down', (c) => throw const KetaException(503, 'down'));
      await TestClient(app, Env()).get('/down');
      await pumpEventQueue();

      expect(
        (_firstSpan(captured)['status'] as Map)['code'],
        SpanStatus.error.index,
      );
    });

    test('499 is unset and 500 is error at the boundary', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/r499', (c) => Response(499));
      app.get('/r500', (c) => Response(500));
      final client = TestClient(app, Env());
      await client.get('/r499');
      await client.get('/r500');
      await pumpEventQueue();

      expect(
        (_spanOf(captured[0])['status'] as Map)['code'],
        SpanStatus.unset.index,
      );
      expect(
        (_spanOf(captured[1])['status'] as Map)['code'],
        SpanStatus.error.index,
      );
    });
  });

  group('span attributes and resilience', () {
    test('the span carries method, route, and status attributes', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/users/:id', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/users/7');
      await pumpEventQueue();

      final attrs = _attrsOf(_firstSpan(captured));
      expect(attrs['http.request.method'], {'stringValue': 'GET'});
      expect(attrs['http.route'], {'stringValue': '/users/:id'});
      expect(attrs['http.response.status_code'], {'intValue': '200'});
    });

    test('a synchronously-throwing sender never fails the request', () async {
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) => throw StateError('down'))));
      app.get('/x', (c) => c.text('ok'));
      final res = await TestClient(app, Env()).get('/x');
      expect(res.status, 200);
      expect(res.text(), 'ok');
      await Future<void>.delayed(Duration.zero);
    });

    test('an async-rejecting sender never fails the request', () async {
      final app = App<Env>()
        ..use(
          otel(exporter: OtlpExporter((p) async => throw StateError('down'))),
        );
      app.get('/x', (c) => c.text('ok'));
      final res = await TestClient(app, Env()).get('/x');
      expect(res.status, 200);
      await Future<void>.delayed(Duration.zero);
    });

    test(
      'one request feeds both the exporter and the metrics registry',
      () async {
        final captured = <String>[];
        final metrics = MetricsRegistry();
        final app = App<Env>()
          ..use(
            otel(
              exporter: OtlpExporter((p) async => captured.add(p)),
              metrics: metrics,
            ),
          );
        app.get('/x', (c) => c.text('ok'));
        await TestClient(app, Env()).get('/x');
        await pumpEventQueue();

        expect(captured, hasLength(1));
        expect(
          metrics.prometheus(),
          contains(
            'keta_requests_total{method="GET",route="/x",status="200"} 1',
          ),
        );
      },
    );
  });

  group('encodeOtlp / OtlpExporter', () {
    test('export of no spans never invokes the sender', () async {
      var calls = 0;
      final exporter = OtlpExporter((p) async => calls++);
      await exporter.export([]);
      expect(calls, 0);
    });

    test('attributes encode bool, double, int, and fallback values', () {
      final doc = encodeOtlp([
        OtelSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'n',
          startUnixNano: 1,
          endUnixNano: 2,
          attributes: {
            'b': true,
            'd': 1.5,
            'i': 7,
            'o': const Duration(seconds: 1),
          },
        ),
      ], 'svc');
      final span = _spanIn(doc);
      final attrs = _attrsOf(span);
      expect(attrs['b'], {'boolValue': true});
      expect(attrs['d'], {'doubleValue': 1.5});
      expect(attrs['i'], {'intValue': '7'});
      expect(attrs['o'], {'stringValue': '0:00:01.000000'});
    });

    test(
      'the envelope carries SERVER kind, string nanos, and no root parent',
      () {
        final doc = encodeOtlp([
          OtelSpan(
            traceId: 'a' * 32,
            spanId: 'b' * 16,
            name: 'GET /x',
            startUnixNano: 1,
            endUnixNano: 2,
            status: SpanStatus.error,
          ),
        ], 'svc');
        final span = _spanIn(doc);
        expect(span['kind'], 2);
        expect(span['startTimeUnixNano'], '1');
        expect(span['endTimeUnixNano'], '2');
        expect((span['status'] as Map)['code'], SpanStatus.error.index);
        expect(span.containsKey('parentSpanId'), isFalse);
      },
    );

    test(
      'a span defaults to SpanStatus.unset with no parent or attributes',
      () {
        const span = OtelSpan(
          traceId: '',
          spanId: '',
          name: 'n',
          startUnixNano: 0,
          endUnixNano: 0,
        );
        expect(span.status, SpanStatus.unset);
        expect(span.parentSpanId, isNull);
        expect(span.attributes, isEmpty);
      },
    );
  });

  group('lifecycle and sampling', () {
    test('export runs off the response hot path', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(otel(exporter: OtlpExporter((p) async => captured.add(p))));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      // The deferred export has not run yet, right after the response.
      expect(captured, isEmpty);
      await pumpEventQueue();
      expect(captured, hasLength(1));
    });

    test('flush awaits a pending export before returning', () async {
      final gate = Completer<void>();
      final captured = <String>[];
      final exporter = OtlpExporter((p) async {
        await gate.future;
        captured.add(p);
      });
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      await pumpEventQueue();
      expect(captured, isEmpty); // the send is gated open

      final flushed = exporter.flush();
      gate.complete();
      await flushed;
      expect(captured, hasLength(1));
    });

    test(
      'an unsampled traceparent is not exported but metrics still record',
      () async {
        final captured = <String>[];
        final metrics = MetricsRegistry();
        final app = App<Env>()
          ..use(
            otel(
              exporter: OtlpExporter((p) async => captured.add(p)),
              metrics: metrics,
            ),
          );
        app.get('/x', (c) => c.text('ok'));
        // flags '00' = the upstream did not sample this trace.
        await TestClient(app, Env()).get(
          '/x',
          headers: {
            'traceparent':
                '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00',
          },
        );
        await pumpEventQueue();

        expect(captured, isEmpty);
        expect(
          metrics.prometheus(),
          contains(
            'keta_requests_total{method="GET",route="/x",status="200"} 1',
          ),
        );
      },
    );

    test('exportUnsampled forces export of an unsampled trace', () async {
      final captured = <String>[];
      final app = App<Env>()
        ..use(
          otel(
            exporter: OtlpExporter((p) async => captured.add(p)),
            exportUnsampled: true,
          ),
        );
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get(
        '/x',
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00',
        },
      );
      await pumpEventQueue();

      expect(captured, hasLength(1)); // exported despite sampled=0
    });

    test('a failing export is logged, not silently dropped', () async {
      final lines = <Map<String, Object?>>[];
      final env = LogEnv(MemLog(lines));
      final app = App<LogEnv>()
        ..use(
          otel(
            exporter: OtlpExporter(
              (p) async => throw StateError('collector down'),
            ),
          ),
        );
      app.get('/x', (c) => c.text('ok'));

      final res = await TestClient(app, env).get('/x');
      expect(res.status, 200); // export failure never fails the request
      await pumpEventQueue();
      expect(lines.any((l) => l['msg'] == 'span export failed'), isTrue);
    });
  });
}
