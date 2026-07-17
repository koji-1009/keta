@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keta_otel/keta_otel.dart';
import 'package:test/test.dart';

void main() {
  test(
    'OtlpExporter.http POSTs OTLP JSON with the configured headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final hits =
          <
            ({
              String method,
              String path,
              String? mime,
              String? auth,
              String body,
            })
          >[];
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        hits.add((
          method: req.method,
          path: req.uri.path,
          mime: req.headers.contentType?.mimeType,
          auth: req.headers.value('authorization'),
          body: body,
        ));
        await req.response.close();
      });

      final exporter = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
        serviceName: 'svc',
        headers: {'authorization': 'Bearer t'},
      );
      await exporter.export([
        OtelSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'GET /x',
          startUnixNano: 1,
          endUnixNano: 2,
        ),
      ]);

      expect(hits, hasLength(1));
      expect(hits.single.method, 'POST');
      expect(hits.single.path, '/v1/traces');
      expect(hits.single.mime, 'application/json');
      expect(hits.single.auth, 'Bearer t');
      final doc = jsonDecode(hits.single.body) as Map<String, Object?>;
      expect(doc['resourceSpans'], hasLength(1));
    },
  );

  test(
    'a non-2xx collector response makes export fail (not silently ok)',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 500;
        await req.response.close();
      });

      final exporter = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      );
      addTearDown(exporter.close);

      await expectLater(
        exporter.export([
          OtelSpan(
            traceId: 'a' * 32,
            spanId: 'b' * 16,
            name: 'GET /x',
            startUnixNano: 1,
            endUnixNano: 2,
          ),
        ]),
        throwsA(isA<HttpException>()),
      );
    },
  );

  test('a collector that accepts the connection and never responds times out '
      'rather than hanging', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Drain the request but never write a response: the client is left
    // waiting on `request.close()`/the response forever without a timeout.
    server.listen((req) async {
      await req.drain<void>();
    });

    final exporter = OtlpExporter.http(
      Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      timeout: const Duration(milliseconds: 100),
    );
    addTearDown(exporter.close);

    await expectLater(
      exporter.export([
        OtelSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'GET /x',
          startUnixNano: 1,
          endUnixNano: 2,
        ),
      ]),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'flush loops until quiescent, awaiting exports enqueued mid-flush',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((req) async {
        await req.drain<void>();
        hits++;
        await req.response.close();
      });

      final exporter = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      );
      addTearDown(exporter.close);

      final span = OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      );

      // Enqueue a second export from inside the first export's completion —
      // simulating a request that finishes and enqueues its span while
      // flush()'s wait is already in flight. A snapshot-based flush would
      // return before this second export lands.
      exporter.enqueue([span]);
      unawaited(exporter.export([span]).then((_) => exporter.enqueue([span])));

      await exporter.flush();
      expect(hits, 3);
    },
  );
}
