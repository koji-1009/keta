import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

class Env {}

/// A minimal, directly-constructed request bypassing [TestClient] — its
/// verb helpers (`get`/`post`/...) only ever send the seven known keta
/// verbs, so a bogus/lowercase method needs the transport seam directly.
class _RawRequest implements TransportRequest {
  _RawRequest(this.method, String path)
    : uri = Uri.parse(path),
      headers = const {};
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  String get remoteAddress => 'test';
  @override
  Future<void> get closed => Completer<void>().future;
}

Map<String, Object?> _spanIn(Map<String, Object?> doc) {
  final rs = (doc['resourceSpans'] as List).first as Map<String, Object?>;
  final ss = (rs['scopeSpans'] as List).first as Map<String, Object?>;
  return (ss['spans'] as List).first as Map<String, Object?>;
}

List<Object?> _spansIn(Map<String, Object?> doc) {
  final rs = (doc['resourceSpans'] as List).first as Map<String, Object?>;
  final ss = (rs['scopeSpans'] as List).first as Map<String, Object?>;
  return ss['spans'] as List;
}

Map<String, Object?> _spanOf(String payload) =>
    _spanIn(jsonDecode(payload) as Map<String, Object?>);

List<Object?> _spansOf(String payload) =>
    _spansIn(jsonDecode(payload) as Map<String, Object?>);

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
      addTearDown(exporter.close);
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
      // Batching defers the actual send to the exporter's own timer/flush,
      // not to the next microtask turn — force it so the span lands here.
      await exporter.flush();

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
    addTearDown(exporter.close);
    final app = App<Env>()..use(otel(exporter: exporter));
    app.get('/boom', (c) => throw StateError('x'));
    final client = TestClient(app, Env());

    await client.get('/boom');
    await exporter.flush();
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
    expect(body, contains('keta_request_duration_seconds_sum{method="GET"'));
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
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      await exporter.flush();

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
          final exporter = OtlpExporter((p) async => captured.add(p));
          addTearDown(exporter.close);
          final app = App<Env>()..use(otel(exporter: exporter));
          app.get('/x', (c) => c.text('ok'));
          await TestClient(app, Env()).get('/x', headers: {'traceparent': bad});
          await exporter.flush();

          final span = _firstSpan(captured);
          expect(span['traceId'], matches(RegExp(r'^[0-9a-f]{32}$')));
          expect(span['traceId'], isNot('0af7651916cd43dd8448eb211c80319c'));
          expect(span.containsKey('parentSpanId'), isFalse);
        },
      );
    }
  });

  group('otelSpanKey exposure', () {
    test(
      'otel exposes the current trace identity to the handler, continuing a '
      'valid incoming traceparent',
      () async {
        final captured = <String>[];
        final exporter = OtlpExporter((p) async => captured.add(p));
        addTearDown(exporter.close);
        OtelSpanContext? seen;
        final app = App<Env>()..use(otel(exporter: exporter));
        app.get('/x', (c) {
          seen = c.get(otelSpanKey);
          return c.text('ok');
        });

        await TestClient(app, Env()).get(
          '/x',
          headers: {
            'traceparent':
                '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
          },
        );
        await exporter.flush();

        // The handler saw the trace identity: the traceId continues the
        // incoming header (core's hardened parse accepted it), and the spanId
        // is the fresh 16-hex id otel minted — not any value the header carried.
        expect(seen, isNotNull);
        expect(seen!.traceId, '0af7651916cd43dd8448eb211c80319c');
        expect(seen!.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));

        // The very ids the handler read are the ones on the exported span, so a
        // handler that logged them can be correlated with the span downstream.
        final span = _firstSpan(captured);
        expect(span['traceId'], seen!.traceId);
        expect(span['spanId'], seen!.spanId);
      },
    );

    test('a root request exposes a minted traceId and spanId', () async {
      OtelSpanContext? seen;
      final app = App<Env>()..use(otel());
      app.get('/x', (c) {
        seen = c.get(otelSpanKey);
        return c.text('ok');
      });
      await TestClient(app, Env()).get('/x');

      expect(seen, isNotNull);
      expect(seen!.traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(seen!.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
    });
  });

  group('/metrics exposition', () {
    test('metricsHandler serves the Prometheus text content-type', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/x', (c) => c.text('ok'));
      app.get('/metrics', metricsHandler(metrics));
      final client = TestClient(app, Env());

      await client.get('/x');
      final res = await client.get('/metrics');

      expect(
        res.headers['content-type'],
        'text/plain; version=0.0.4; charset=utf-8',
      );
      // Conformance-renamed families: a seconds-unit summary, no `_ms` name.
      expect(res.text(), contains('# TYPE keta_request_duration_seconds summary'));
      expect(
        res.text(),
        contains('keta_request_duration_seconds_sum{method="GET"'),
      );
      expect(res.text(), isNot(contains('keta_request_duration_ms')));
    });
  });

  group('span status', () {
    test('a thrown NotFound (404) yields a 4xx unset span', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/missing', (c) => throw const NotFound('nope'));
      final res = await TestClient(app, Env()).get('/missing');
      await exporter.flush();

      expect(res.status, 404);
      final span = _firstSpan(captured);
      expect((span['status'] as Map)['code'], SpanStatus.unset.index);
      expect(_attrsOf(span)['http.response.status_code'], {'intValue': '404'});
    });

    test('a thrown Unavailable (503) yields an error span', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/down', (c) => throw const Unavailable('down'));
      await TestClient(app, Env()).get('/down');
      await exporter.flush();

      expect(
        (_firstSpan(captured)['status'] as Map)['code'],
        SpanStatus.error.index,
      );
    });

    test('499 is unset and 500 is error at the boundary', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/r499', (c) => Response(499));
      app.get('/r500', (c) => Response(500));
      final client = TestClient(app, Env());
      await client.get('/r499');
      await client.get('/r500');
      await exporter.flush();

      // Both spans are still queued (nothing has drained yet) when flush()
      // runs, so batching coalesces them into a single POST — unlike the
      // old one-POST-per-request design, `captured` has one payload holding
      // both spans, not two payloads of one each.
      expect(captured, hasLength(1));
      final spans = _spansOf(captured.single).cast<Map<String, Object?>>();
      expect((spans[0]['status'] as Map)['code'], SpanStatus.unset.index);
      expect((spans[1]['status'] as Map)['code'], SpanStatus.error.index);
    });
  });

  group('span attributes and resilience', () {
    test('the span carries method, route, and status attributes', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/users/:id', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/users/7');
      await exporter.flush();

      final attrs = _attrsOf(_firstSpan(captured));
      expect(attrs['http.request.method'], {'stringValue': 'GET'});
      expect(attrs['http.route'], {'stringValue': '/users/:id'});
      expect(attrs['http.response.status_code'], {'intValue': '200'});
    });

    test('a synchronously-throwing sender never fails the request', () async {
      final exporter = OtlpExporter((p) => throw StateError('down'));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      final res = await TestClient(app, Env()).get('/x');
      expect(res.status, 200);
      expect(res.text(), 'ok');
      // The span only sits in the queue until drained — flush() to actually
      // exercise the throwing sender and confirm it still doesn't surface.
      await exporter.flush();
    });

    test('an async-rejecting sender never fails the request', () async {
      final exporter = OtlpExporter((p) async => throw StateError('down'));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      final res = await TestClient(app, Env()).get('/x');
      expect(res.status, 200);
      await exporter.flush();
    });

    test(
      'one request feeds both the exporter and the metrics registry',
      () async {
        final captured = <String>[];
        final metrics = MetricsRegistry();
        final exporter = OtlpExporter((p) async => captured.add(p));
        addTearDown(exporter.close);
        final app = App<Env>()..use(otel(exporter: exporter, metrics: metrics));
        app.get('/x', (c) => c.text('ok'));
        await TestClient(app, Env()).get('/x');
        await exporter.flush();

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

  group('route cardinality', () {
    test('an unmatched request records metrics under the fixed label, not the '
        'raw path', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/users/:id', (c) => c.text('ok'));
      final client = TestClient(app, Env());

      await client.get('/scanner-path-123');
      await client.get('/another-probe');
      final body = metrics.prometheus();

      expect(
        body,
        contains(
          'keta_requests_total{method="GET",route="(unmatched)",status="404"} 2',
        ),
      );
      expect(body, isNot(contains('scanner-path-123')));
      expect(body, isNot(contains('another-probe')));
    });

    test('a matched request still records its route template', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/users/:id', (c) => c.text('ok'));
      final client = TestClient(app, Env());

      await client.get('/users/42');

      expect(
        metrics.prometheus(),
        contains(
          'keta_requests_total{method="GET",route="/users/:id",status="200"} 1',
        ),
      );
    });

    test(
      'an unmatched request emits a path-free, method-only span name',
      () async {
        final captured = <String>[];
        final exporter = OtlpExporter((p) async => captured.add(p));
        addTearDown(exporter.close);
        final app = App<Env>()..use(otel(exporter: exporter));
        app.get('/users/:id', (c) => c.text('ok'));

        await TestClient(app, Env()).get('/scanner-path-123');
        await exporter.flush();

        final span = _firstSpan(captured);
        expect(span['name'], 'GET');
        final attrs = _attrsOf(span);
        expect(attrs.containsKey('http.route'), isFalse);
      },
    );

    test('a matched request keeps its templated span name', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/users/:id', (c) => c.text('ok'));

      await TestClient(app, Env()).get('/users/42');
      await exporter.flush();

      final span = _firstSpan(captured);
      expect(span['name'], 'GET /users/:id');
      expect(_attrsOf(span)['http.route'], {'stringValue': '/users/:id'});
    });
  });

  group('method cardinality', () {
    test('distinct bogus methods do not mint per-method series, just the '
        'fixed label', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/x', (c) => c.text('ok'));
      final router = app.compile(Env());

      // /x exists (registered for GET), so an unrecognized method hits the
      // 405 branch (RFC 9110 §15.5.6) rather than 404 — either way the
      // route axis folds to "(unmatched)" and, after this fix, so does the
      // method axis.
      for (var i = 0; i < 500; i++) {
        await router.dispatch(_RawRequest('BOGUS-$i', '/x'));
      }
      final body = metrics.prometheus();

      expect(
        body,
        contains(
          'keta_requests_total'
          '{method="(other)",route="(unmatched)",status="405"} 500',
        ),
      );
      expect(body, isNot(contains('BOGUS-')));
      // Exactly one series for the (other) label, not one per bogus verb. Three
      // lines now carry it, not two: keta_requests_total, plus the duration
      // summary's `_sum` and its `_count` (the conformance rename added the
      // summary's own count line alongside the sum).
      expect('(other)'.allMatches(body).length, 3);
    });

    test(
      "a bogus method's span name and attribute use the fixed label",
      () async {
        final captured = <String>[];
        final exporter = OtlpExporter((p) async => captured.add(p));
        addTearDown(exporter.close);
        final app = App<Env>()..use(otel(exporter: exporter));
        app.get('/x', (c) => c.text('ok'));
        final router = app.compile(Env());

        await router.dispatch(_RawRequest('BREW-COFFEE', '/x'));
        await exporter.flush();

        final span = _firstSpan(captured);
        // The path exists but the method doesn't match any registered route
        // (405), so there's no template to fold into the name — same as an
        // unmatched-path span, just method-only.
        expect(span['name'], '(other)');
        expect(_attrsOf(span)['http.request.method'], {
          'stringValue': '(other)',
        });
        expect(_attrsOf(span).containsKey('http.route'), isFalse);
      },
    );

    test(
      'a known verb sent lowercase still folds to its uppercase label',
      () async {
        final metrics = MetricsRegistry();
        final app = App<Env>()..use(otel(metrics: metrics));
        app.get('/x', (c) => c.text('ok'));
        final router = app.compile(Env());

        // The router itself matches methods case-sensitively (a lowercase
        // "get" does not hit the registered GET route, hence the 405 and
        // "(unmatched)" route), but the method label folds to the known verb
        // regardless of case: it is not "(other)".
        await router.dispatch(_RawRequest('get', '/x'));
        final body = metrics.prometheus();

        expect(
          body,
          contains(
            'keta_requests_total{method="GET",route="(unmatched)",status="405"} 1',
          ),
        );
        expect(body, isNot(contains('(other)')));
      },
    );

    test('a registered GET request keeps the GET label untouched', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/users/:id', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/users/1');

      expect(
        metrics.prometheus(),
        contains(
          'keta_requests_total{method="GET",route="/users/:id",status="200"} 1',
        ),
      );
    });
  });

  group('duration precision', () {
    test('fast handlers record a fractional, nonzero duration (not truncated '
        'to 0)', () async {
      final metrics = MetricsRegistry();
      final app = App<Env>()..use(otel(metrics: metrics));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');

      final match = RegExp(
        r'keta_request_duration_seconds_sum\{method="GET",route="/x",'
        r'status="200"\} (\S+)',
      ).firstMatch(metrics.prometheus());
      expect(match, isNotNull);
      // Before this fix, `elapsedMilliseconds` truncated almost every
      // in-process handler's duration to 0; a handler this fast would
      // have recorded exactly 0 every single time.
      expect(double.parse(match!.group(1)!), greaterThan(0));
    });
  });

  group('encodeOtlp / OtlpExporter', () {
    test('export of no spans never invokes the sender', () async {
      var calls = 0;
      final exporter = OtlpExporter((p) async => calls++);
      addTearDown(exporter.close);
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

  group('OtlpExporter batching', () {
    final span = OtelSpan(
      traceId: 'a' * 32,
      spanId: 'b' * 16,
      name: 'GET /x',
      startUnixNano: 1,
      endUnixNano: 2,
    );

    test('N enqueues coalesce into a single batched POST on flush', () async {
      final payloads = <String>[];
      final exporter = OtlpExporter((p) async => payloads.add(p));
      addTearDown(exporter.close);

      // Simulates 10 served requests each enqueuing their own span — the
      // exact pattern that used to mean 10 separate POSTs (one per
      // request). Batching means they share one.
      for (var i = 0; i < 10; i++) {
        exporter.enqueue([span]);
      }
      await exporter.flush();

      expect(payloads, hasLength(1));
      expect(_spansOf(payloads.single), hasLength(10));
    });

    test(
      'a batch larger than maxBatchSize is drained over multiple POSTs',
      () async {
        final payloads = <String>[];
        final exporter = OtlpExporter(
          (p) async => payloads.add(p),
          maxBatchSize: 4,
        );
        addTearDown(exporter.close);

        for (var i = 0; i < 10; i++) {
          exporter.enqueue([span]);
        }
        await exporter.flush();

        // 10 spans at up to 4 per POST: 3 POSTs (4, 4, 2), every span sent.
        expect(payloads, hasLength(3));
        expect(payloads.map(_spansOf).map((s) => s.length).toList(), [4, 4, 2]);
      },
    );

    test('a full queue drops the oldest span and reports the count once, on '
        'the next successful export', () async {
      final payloads = <String>[];
      final warnings = <MapEntry<String, Map<String, Object?>>>[];
      final exporter = OtlpExporter(
        (p) async => payloads.add(p),
        maxQueueSize: 3,
        onWarn: (msg, fields) => warnings.add(MapEntry(msg, fields)),
      );
      addTearDown(exporter.close);

      // 5 spans into a queue capped at 3: the oldest 2 are evicted.
      for (var i = 0; i < 5; i++) {
        exporter.enqueue([span]);
      }
      await exporter.flush();

      expect(_spansOf(payloads.single), hasLength(3));
      expect(warnings, hasLength(1));
      expect(warnings.single.key, 'OTLP spans dropped');
      expect(warnings.single.value['dropped'], 2);

      // Nothing new was dropped, so a later successful export must not
      // repeat the report — it fires once, not on every export.
      exporter.enqueue([span]);
      await exporter.flush();
      expect(warnings, hasLength(1));
    });

    test(
      'close cancels the periodic timer; none remains pending after',
      () async {
        Timer? captured;
        final zone = Zone.current.fork(
          specification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              final timer = parent.createPeriodicTimer(
                zone,
                duration,
                callback,
              );
              captured = timer;
              return timer;
            },
          ),
        );

        late OtlpExporter exporter;
        await zone.run(() async {
          exporter = OtlpExporter(
            (p) async {},
            exportInterval: const Duration(milliseconds: 10),
          );
        });

        expect(captured, isNotNull);
        expect(captured!.isActive, isTrue);
        await exporter.close();
        expect(captured!.isActive, isFalse);
      },
    );
  });

  group('lifecycle and sampling', () {
    test('export is deferred off the request path until flushed', () async {
      final captured = <String>[];
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      // Batching defers the POST to the periodic timer or an explicit
      // flush — never to the request itself, nor even to the next
      // microtask turn.
      expect(captured, isEmpty);
      await exporter.flush();
      expect(captured, hasLength(1));
    });

    test('flush drains the queue and awaits the resulting export before '
        'returning', () async {
      final gate = Completer<void>();
      final captured = <String>[];
      final exporter = OtlpExporter((p) async {
        await gate.future;
        captured.add(p);
      });
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get('/x');
      await pumpEventQueue();
      // The span is only queued so far; nothing is sent (and so nothing
      // is gated) until flush() below drains it.
      expect(captured, isEmpty);

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
        final exporter = OtlpExporter((p) async => captured.add(p));
        addTearDown(exporter.close);
        final app = App<Env>()..use(otel(exporter: exporter, metrics: metrics));
        app.get('/x', (c) => c.text('ok'));
        // flags '00' = the upstream did not sample this trace.
        await TestClient(app, Env()).get(
          '/x',
          headers: {
            'traceparent':
                '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00',
          },
        );
        // No span is ever enqueued for an unsampled trace, so there's
        // nothing for flush() to surface — captured stays empty regardless.
        await exporter.flush();

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
      final exporter = OtlpExporter((p) async => captured.add(p));
      addTearDown(exporter.close);
      final app = App<Env>()
        ..use(otel(exporter: exporter, exportUnsampled: true));
      app.get('/x', (c) => c.text('ok'));
      await TestClient(app, Env()).get(
        '/x',
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00',
        },
      );
      await exporter.flush();

      expect(captured, hasLength(1)); // exported despite sampled=0
    });

    test('a failing batch export is reported via the exporter\'s own onWarn '
        'hook, not silently dropped', () async {
      final warnings = <Map<String, Object?>>[];
      final exporter = OtlpExporter(
        (p) async => throw StateError('collector down'),
        onWarn: (msg, fields) => warnings.add({'msg': msg, ...fields}),
      );
      addTearDown(exporter.close);
      final app = App<Env>()..use(otel(exporter: exporter));
      app.get('/x', (c) => c.text('ok'));

      final res = await TestClient(app, Env()).get('/x');
      expect(res.status, 200); // export failure never fails the request
      // Batching moved the exporter's lifecycle off any single request's
      // Context (a batch can span many requests' spans), so a failed send
      // is no longer routed through `c.log` per request — it's reported
      // through the exporter's own `onWarn` hook, wired once at
      // construction, instead.
      await exporter.flush();
      expect(warnings.any((l) => l['msg'] == 'span export failed'), isTrue);
    });
  });
}
