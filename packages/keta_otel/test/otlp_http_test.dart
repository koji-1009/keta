@TestOn('vm')
library;

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
}
