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
      'rather than hanging, and observes its socket actually close '
      'afterward', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Drain the request but never write a response: the client is left
    // waiting on `request.close()`/the response forever without a timeout.
    // Detaching the socket (instead of just letting the request hang) gives
    // this test a direct, server-side view of the TCP connection itself —
    // the resource-lifecycle dimension a bare "the Future throws
    // TimeoutException" assertion can't see: a stuck collector could leak
    // one ESTABLISHED socket per export even while every export "fails
    // correctly" from the client's point of view.
    final socketClosed = Completer<void>();
    void completeOnce() {
      if (!socketClosed.isCompleted) socketClosed.complete();
    }

    Socket? detached;
    addTearDown(() => detached?.destroy()); // safety net if the test fails
    // before onDone/onError below ever fires.
    server.listen((req) async {
      await req.drain<void>();
      final socket = await req.response.detachSocket(writeHeaders: false);
      detached = socket;
      socket.listen(
        (_) {},
        onDone: () {
          completeOnce();
          socket.destroy();
        },
        onError: (_) {
          completeOnce();
          socket.destroy();
        },
        cancelOnError: true,
      );
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

    // Without aborting the in-flight request on timeout, the client never
    // tells the socket to stop waiting, so the collector would never see it
    // close — this would hang until the test framework's own timeout fires.
    await socketClosed.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail(
        'server-observed socket never closed after the export timed out',
      ),
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
