/// `OtlpExporter.http` against a real socket: request framing, timeouts,
/// retry/backoff (including Retry-After clamping), and shutdown draining.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keta_otel/keta_otel.dart';
// A debug-only seam (mirrors keta's `debugWebSocketChannel`): not part of the
// public API, so it is imported straight from `src/` rather than re-exported.
import 'package:keta_otel/src/otlp.dart'
    show debugActiveSleepCount, debugConnectionTimeout;
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
    'OtlpExporter.http wires connectionTimeout to the per-attempt timeout',
    () async {
      // Guards the connect-phase hang this exporter is otherwise exposed to:
      // `pending.timeout`'s `request?.abort()` can only reach a socket that
      // already exists, so a SYN blackholed by an unreachable/firewalled peer
      // — `request` still null — would run unbounded without a
      // `connectionTimeout` on the client. There is no portable, deterministic
      // way to fabricate that exact hang in a unit test (a closed port RSTs
      // fast, which is a different, already-covered path — see "accepts the
      // connection and never responds" above), so this pins the mechanism the
      // fix relies on instead: the client is actually configured with a
      // bound, and it is [timeout] itself, not some derived fraction of it.
      final exporterDefault = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:1/v1/traces'), // never dialed.
      );
      addTearDown(exporterDefault.close);
      expect(
        debugConnectionTimeout(exporterDefault),
        const Duration(seconds: 10), // OtlpExporter.http's default `timeout`.
      );

      final exporterCustom = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:1/v1/traces'),
        timeout: const Duration(milliseconds: 250),
      );
      addTearDown(exporterCustom.close);
      expect(
        debugConnectionTimeout(exporterCustom),
        const Duration(milliseconds: 250),
      );
    },
  );

  // Still valid after the batching redesign, unchanged: `enqueue` no longer
  // sends synchronously, but the three sends below are never simultaneously
  // queued — each is separated by an in-flight `export()`'s completion — so
  // there is no opportunity for batching to coalesce any two of them into a
  // single POST. `hits` still lands on exactly 3: one for the queued span
  // `flush()` drains first, one for the direct `export()`, and one for the
  // span enqueued from that export's completion callback, which flush()'s
  // quiescence loop picks up on its next pass.
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

  test('a 429 with Retry-After is retried, then the batch succeeds', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final statuses = <int>[];
    server.listen((req) async {
      await req.drain<void>();
      // First attempt is throttled with a Retry-After the client must honor;
      // the retry lands on 200.
      if (statuses.isEmpty) {
        req.response.statusCode = 429;
        req.response.headers.set('retry-after', '0');
      } else {
        req.response.statusCode = 200;
      }
      statuses.add(req.response.statusCode);
      await req.response.close();
    });

    final exporter = OtlpExporter.http(
      Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      // Zero fallback keeps the test fast; Retry-After: 0 is honored as an
      // immediate retry either way.
      retryBackoff: Duration.zero,
    );
    addTearDown(exporter.close);

    // export() completing (not throwing) is the whole assertion: a single
    // attempt would have surfaced the 429 as an HttpException.
    await exporter.export([
      OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      ),
    ]);

    expect(statuses, [429, 200]); // throttled once, then accepted.
  });

  test(
    'a persistent 503 exhausts retries; the dropped batch is reported on the '
    'next successful export',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((req) async {
        await req.drain<void>();
        hits++;
        // 503 for the first batch's every attempt (1 + maxRetries), then 200
        // so a later batch succeeds and can surface the deferred drop report.
        req.response.statusCode = hits <= 3 ? 503 : 200;
        await req.response.close();
      });

      final warnings = <MapEntry<String, Map<String, Object?>>>[];
      final exporter = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
        maxRetries: 2, // 3 attempts total for the doomed batch.
        retryBackoff: Duration.zero,
        onWarn: (msg, fields) => warnings.add(MapEntry(msg, fields)),
      );
      addTearDown(exporter.close);

      final span = OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      );

      // Batch 1: 3 attempts, all 503 -> exhausted -> dropped (1 span). The drop
      // is remembered, not reported yet (no successful export to carry it).
      exporter.enqueue([span]);
      await exporter.flush();
      expect(hits, 3);
      expect(warnings.any((w) => w.key == 'span export failed'), isTrue);
      expect(warnings.any((w) => w.key == 'OTLP spans dropped'), isFalse);

      // Batch 2 succeeds (4th request 200) and carries the deferred drop count.
      exporter.enqueue([span]);
      await exporter.flush();
      final dropReport = warnings.firstWhere(
        (w) => w.key == 'OTLP spans dropped',
      );
      expect(dropReport.value['dropped'], 1);
    },
  );

  test(
    'a huge Retry-After is clamped: the retry waits the cap, not the header',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final statuses = <int>[];
      server.listen((req) async {
        await req.drain<void>();
        // First attempt throttles with an absurd Retry-After (an hour). An
        // unclamped client would honor it literally and park the batch for
        // 3600s; the retry must instead fire after the small cap below.
        if (statuses.isEmpty) {
          req.response.statusCode = 429;
          req.response.headers.set('retry-after', '3600');
        } else {
          req.response.statusCode = 200;
        }
        statuses.add(req.response.statusCode);
        await req.response.close();
      });

      final exporter = OtlpExporter.http(
        Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
        // 50ms cap: the honored 3600s Retry-After is clamped down to this, so
        // the whole export completes in well under the 2s bound asserted below
        // rather than in an hour.
        maxRetryDelay: const Duration(milliseconds: 50),
      );
      addTearDown(exporter.close);

      final sw = Stopwatch()..start();
      await exporter.export([
        OtelSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'GET /x',
          startUnixNano: 1,
          endUnixNano: 2,
        ),
      ]);
      sw.stop();

      expect(statuses, [429, 200]); // throttled once, then accepted.
      // Proves the header was clamped, not honored: an honored 3600s would
      // have blown far past this.
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test('close() cuts a batch mid-retry-sleep: it completes promptly and the '
      'batch is counted as dropped', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Always throttle with a large Retry-After: the batch can never succeed,
    // so it sits in its (clamped) retry sleep until close() cuts it loose.
    server.listen((req) async {
      await req.drain<void>();
      req.response.statusCode = 429;
      req.response.headers.set('retry-after', '9999');
      await req.response.close();
    });

    final warnings = <MapEntry<String, Map<String, Object?>>>[];
    final exporter = OtlpExporter.http(
      Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      // A large clamp so the sleep would be long (30s) absent the shutdown
      // cut — the wall-clock assertion below is meaningful only because the
      // sleep it races is far longer than the bound.
      maxRetryDelay: const Duration(seconds: 30),
      maxRetries: 5,
      exportInterval: const Duration(milliseconds: 20),
      onWarn: (msg, fields) => warnings.add(MapEntry(msg, fields)),
    );

    exporter.enqueue([
      OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      ),
    ]);

    // Let the periodic timer drain the batch and park it in its retry sleep.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final sw = Stopwatch()..start();
    await exporter.close();
    sw.stop();

    // Bounded: close() cut the 30s sleep instead of waiting it out.
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    // The cut batch failed like any rejected send, so its span is folded
    // into the dropped count and surfaced as an export failure.
    expect(warnings.any((w) => w.key == 'span export failed'), isTrue);
  });

  test('many sequential clamped retries never grow the active-sleep set past '
      'the single in-flight sleep, and it settles to empty', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Always 429, no Retry-After: every retry falls back to the fixed
    // (tiny) retryBackoff, so several real sleeps fire back-to-back.
    server.listen((req) async {
      await req.drain<void>();
      req.response.statusCode = 429;
      await req.response.close();
    });

    final exporter = OtlpExporter.http(
      Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
      maxRetries: 6,
      retryBackoff: const Duration(milliseconds: 5),
      maxRetryDelay: const Duration(milliseconds: 5),
      // Draining happens only via the explicit flush() below.
      exportInterval: Duration.zero,
      onWarn: (_, _) {},
    );
    addTearDown(exporter.close);

    exporter.enqueue([
      OtelSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'GET /x',
        startUnixNano: 1,
        endUnixNano: 2,
      ),
    ]);

    // Sample the debug seam throughout the retry storm (6 back-to-back
    // sleeps), not just at the end — an earlier version of `_sleepUnless`
    // registered a `.then` listener on the shared `closing` future per
    // sleep, and a Dart Future never releases a listener until it
    // completes, so those would have piled up for the exporter's whole
    // lifetime instead of clearing between retries.
    var maxSeen = 0;
    final sampler = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final n = debugActiveSleepCount(exporter);
      if (n > maxSeen) maxSeen = n;
    });
    await exporter.flush();
    sampler.cancel();

    // This exporter retries one batch at a time in a loop rather than
    // running sleeps concurrently, so at most one is ever in flight — and
    // every one of them is gone once it settles.
    expect(maxSeen, lessThanOrEqualTo(1));
    expect(debugActiveSleepCount(exporter), 0);
  });
}
