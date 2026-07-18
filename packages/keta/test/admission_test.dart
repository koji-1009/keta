/// Owns the admission-control middleware: rateLimit()'s token bucket (burst,
/// time-based refill, per-key isolation, null-key exemption, honest Retry-After,
/// and the full-bucket eviction that bounds memory against a hostile key space)
/// and concurrencyLimit()'s load-shedding cap (admit/refuse/release across
/// success, error, and streaming responses, with no slot ever leaked).
library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta/src/admission.dart' show ConcurrencyLimiter, RateLimiter;
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// A controllable monotonic clock in microseconds, so refill is exercised by
/// advancing time rather than sleeping.
class _FakeClock {
  int micros = 0;
  int call() => micros;
  void advance(Duration d) => micros += d.inMicroseconds;
}

/// Drives [mw] once with the given key header against a fixed 200 handler and
/// returns the response — the single-middleware harness for the rate limiter.
Future<Response> hit(Middleware<Env> mw, String keyValue) => run(
  mw,
  testContext(newEnv(), headers: {'x-key': keyValue}),
  Response.text('ok'),
);

void main() {
  // key by the `x-key` header so distinct keys are trivially expressible.
  Object? byHeader(Context<Env> c) => c.header('x-key');

  group('rateLimit — construction validation', () {
    test('capacity < 1 is an authoring defect', () {
      expect(
        () => rateLimit<Env>(
          key: byHeader,
          capacity: 0,
          refillPeriod: const Duration(seconds: 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a non-positive refillPeriod is an authoring defect', () {
      expect(
        () => rateLimit<Env>(
          key: byHeader,
          capacity: 1,
          refillPeriod: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('rateLimit — burst then refusal', () {
    test('admits up to capacity, then refuses with 429', () async {
      final mw = RateLimiter<Env>(
        key: byHeader,
        capacity: 3,
        refillPeriod: const Duration(seconds: 1),
        clock: _FakeClock().call,
      ).middleware;

      for (var i = 0; i < 3; i++) {
        expect(
          (await hit(mw, 'a')).status,
          200,
          reason: 'burst token ${i + 1}',
        );
      }
      expect((await hit(mw, 'a')).status, 429, reason: 'bucket now empty');
    });
  });

  group('rateLimit — refill over time', () {
    test('one token accrues per refillPeriod, capped at capacity', () async {
      final clock = _FakeClock();
      final mw = RateLimiter<Env>(
        key: byHeader,
        capacity: 2,
        refillPeriod: const Duration(seconds: 1),
        clock: clock.call,
      ).middleware;

      // Drain the burst.
      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 429);

      // One period → exactly one token.
      clock.advance(const Duration(seconds: 1));
      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 429);

      // Long idle refills to the cap, not beyond: two tokens, no more.
      clock.advance(const Duration(seconds: 10));
      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 429);
    });
  });

  group('rateLimit — per-key isolation', () {
    test('one key exhausting its budget never starves another', () async {
      final mw = RateLimiter<Env>(
        key: byHeader,
        capacity: 1,
        refillPeriod: const Duration(seconds: 60),
        clock: _FakeClock().call,
      ).middleware;

      expect((await hit(mw, 'a')).status, 200);
      expect((await hit(mw, 'a')).status, 429); // 'a' drained
      expect((await hit(mw, 'b')).status, 200); // 'b' untouched
    });
  });

  group('rateLimit — null key exemption', () {
    test('a null key is admitted and consults no bucket', () async {
      final limiter = RateLimiter<Env>(
        key: (_) => null,
        capacity: 1,
        refillPeriod: const Duration(seconds: 60),
        clock: _FakeClock().call,
      );
      final mw = limiter.middleware;

      for (var i = 0; i < 5; i++) {
        expect((await hit(mw, 'ignored')).status, 200);
      }
      // Never a bucket created — the exempt path adds no key-space pressure.
      expect(limiter.bucketCount, 0);
    });
  });

  group('rateLimit — honest Retry-After', () {
    test('states whole seconds until a token exists, never sooner', () async {
      final clock = _FakeClock();
      final mw = RateLimiter<Env>(
        key: byHeader,
        capacity: 1,
        refillPeriod: const Duration(seconds: 2),
        clock: clock.call,
      ).middleware;

      expect((await hit(mw, 'a')).status, 200); // spend the only token

      // Empty at t=0: a full period (2s) until the next token.
      final r0 = await hit(mw, 'a');
      expect(r0.status, 429);
      expect(r0.headers['retry-after'], ['2']);

      // Halfway (1s in): 0.5 token accrued, ~1s left, rounded up to 1.
      clock.advance(const Duration(seconds: 1));
      final r1 = await hit(mw, 'a');
      expect(r1.status, 429);
      expect(r1.headers['retry-after'], ['1']);

      // A partial token still rounds up (never advises retrying before a whole
      // token exists): 1.5s in leaves 0.5s, reported as 1.
      clock.advance(const Duration(milliseconds: 500));
      final r2 = await hit(mw, 'a');
      expect(r2.status, 429);
      expect(r2.headers['retry-after'], ['1']);

      // A full period from empty → the token is back and the request is admitted.
      clock.advance(const Duration(seconds: 2));
      expect((await hit(mw, 'a')).status, 200);
    });
  });

  group('rateLimit — memory bound (eviction of full buckets)', () {
    test('a sweep reclaims buckets that have refilled to capacity', () async {
      final clock = _FakeClock();
      // Small sweep threshold so eviction is observable without minting 1024
      // keys; capacity 1 so a single hit drains a bucket below full.
      final limiter = RateLimiter<Env>(
        key: byHeader,
        capacity: 1,
        refillPeriod: const Duration(seconds: 1),
        clock: clock.call,
        sweepThreshold: 4,
      );
      final mw = limiter.middleware;

      // Four distinct keys, each drained to 0 tokens at t=0. The 4th hit reaches
      // the threshold and triggers a sweep, but at t=0 every bucket is below
      // capacity (stateful), so none are evicted.
      for (final k in ['k0', 'k1', 'k2', 'k3']) {
        expect((await hit(mw, k)).status, 200);
      }
      expect(limiter.bucketCount, 4);

      // Let the four idle buckets refill to full capacity.
      clock.advance(const Duration(seconds: 5));

      // Four fresh keys. The 8th live bucket re-triggers the sweep, which now
      // finds k0..k3 refilled to capacity — byte-equivalent to fresh — and
      // evicts them, leaving only the four still-draining newcomers.
      for (final k in ['k4', 'k5', 'k6', 'k7']) {
        expect((await hit(mw, k)).status, 200);
      }
      expect(
        limiter.bucketCount,
        4,
        reason: 'full buckets reclaimed; only throttled keys remain',
      );
    });
  });

  group('rateLimit — end to end through the pipeline', () {
    test('429 body and Retry-After surface via the full chain', () async {
      final app = App<Env>()
        ..use(
          rateLimit(
            key: (c) => c.remoteAddress,
            capacity: 1,
            refillPeriod: const Duration(seconds: 60),
          ),
        );
      app.get('/x', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      expect((await client.get('/x')).status, 200);
      final limited = await client.get('/x');
      expect(limited.status, 429);
      expect(limited.json(), {'error': 'rate limit exceeded'});
      expect(limited.headers['retry-after'], isNotNull);
    });
  });

  group('concurrencyLimit — construction validation', () {
    test('maxInFlight < 1 is an authoring defect', () {
      expect(
        () => concurrencyLimit<Env>(maxInFlight: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('concurrencyLimit — admit, refuse, release', () {
    test('sheds past the cap with 503 and releases on completion', () async {
      final limiter = ConcurrencyLimiter<Env>(maxInFlight: 2);
      final mw = limiter.middleware;
      final gate = Completer<void>();

      Future<Response> fire() => Future.value(
        mw(testContext(newEnv()), (_) async {
          await gate.future;
          return Response.text('ok');
        }),
      );

      final inflight = [fire(), fire()];
      await pumpEventQueue();
      expect(limiter.inFlight, 2, reason: 'both slots taken');

      // A third arrives at capacity → shed immediately.
      final shed = await Future.value(
        mw(testContext(newEnv()), (_) => Response.text('never')),
      );
      expect(shed.status, 503);
      expect(shed.body, isNot(equals('never')), reason: 'handler not run');
      expect(limiter.inFlight, 2, reason: 'a shed request takes no slot');

      gate.complete();
      final done = await Future.wait(inflight);
      expect(done.every((r) => r.status == 200), isTrue);
      expect(limiter.inFlight, 0, reason: 'both slots released');
    });

    test('releases the slot on a thrown error (no leak)', () {
      final limiter = ConcurrencyLimiter<Env>(maxInFlight: 1);
      final mw = limiter.middleware;

      expect(
        () => mw(testContext(newEnv()), (_) => throw const BadRequest('boom')),
        throwsA(isA<BadRequest>()),
      );
      expect(limiter.inFlight, 0, reason: 'a failed handler frees its slot');

      // The freed slot admits the next request.
      final ok = mw(testContext(newEnv()), (_) => Response.text('ok'));
      expect((ok as Response).status, 200);
    });

    test('releases the slot on a rejected Future (no leak)', () async {
      final limiter = ConcurrencyLimiter<Env>(maxInFlight: 1);
      final mw = limiter.middleware;

      final result = mw(
        testContext(newEnv()),
        (_) async => throw const BadRequest('boom'),
      );
      await expectLater(result, throwsA(isA<BadRequest>()));
      expect(limiter.inFlight, 0);
    });

    test('a streaming response releases its slot when produced, not when the '
        'stream ends', () async {
      final limiter = ConcurrencyLimiter<Env>(maxInFlight: 1);
      final mw = limiter.middleware;
      // A still-open body stream that the middleware never consumes: the slot
      // must be released at Response production, not when (or if) this stream is
      // ever drained. A subscription is attached only so teardown can close the
      // controller cleanly — the middleware itself touches neither.
      final controller = StreamController<List<int>>();
      final drain = controller.stream.listen(null);
      addTearDown(() async {
        await drain.cancel();
        await controller.close();
      });

      final streaming = await Future.value(
        mw(
          testContext(newEnv()),
          (_) => Response(200, body: controller.stream),
        ),
      );
      expect(streaming.status, 200);
      // The body stream is still open, yet the slot is already released — the cap
      // bounds request processing, not connection lifetime.
      expect(limiter.inFlight, 0);

      // So a second request is admitted despite the first stream being live.
      final second = mw(testContext(newEnv()), (_) => Response.text('ok'));
      expect((second as Response).status, 200);
    });
  });

  group('concurrencyLimit — end to end through the pipeline', () {
    test('503 shed surfaces via the full chain', () async {
      final app = App<Env>()..use(concurrencyLimit(maxInFlight: 1));
      final gate = Completer<void>();
      app.get('/slow', (c) async {
        await gate.future;
        return c.text('ok');
      });
      final client = TestClient(app, newEnv());

      final first = client.get('/slow'); // takes the only slot, hangs
      await pumpEventQueue();
      final shed = await client.get('/slow'); // over cap → 503
      expect(shed.status, 503);
      expect(shed.json(), {'error': 'server at capacity'});

      gate.complete();
      expect((await first).status, 200);
    });
  });
}
