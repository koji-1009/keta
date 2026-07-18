/// Admission control middleware — a token-bucket [rateLimit] and an in-flight
/// [concurrencyLimit] load-shedder. Both are Ring 0: zero dependencies, entirely
/// in-process, and scoped to the isolate that runs them.
///
/// ## Per-isolate, not process-wide
///
/// Neither limiter coordinates across isolates. Under `serve(isolates: n)` each
/// worker isolate boots its own middleware with its own buckets and its own
/// in-flight counter, so the *effective* limit is multiplied by `n`: a
/// `capacity: 100` rate limit under 4 isolates admits up to 400 concurrent
/// bursts across the process, and a `maxInFlight: 50` cap admits up to 200. This
/// is stated plainly rather than papered over — process-wide or cluster-wide
/// coordination needs shared state (a store, a broker) that Ring 0 does not
/// have. Size the per-isolate limit as `desired / isolates`, or run these behind
/// a single-isolate front if an exact global bound is required.
library;

import 'dart:math' as math;

import 'app.dart';
import 'chain.dart';
import 'context.dart';
import 'response.dart';

/// Rate-limits requests with a per-key token bucket: each key gets a bucket of
/// [capacity] tokens that refills one token every [refillPeriod]; a request
/// spends one token, and a request that finds an empty bucket is refused with
/// `429 Too Many Requests`.
///
/// [key] maps a request to the bucket it draws from — by client IP
/// (`c.remoteAddress`), by authenticated principal, by API token, whatever the
/// application decides. Returning `null` **exempts** the request from limiting
/// entirely (it is admitted without touching any bucket): use it for health
/// checks, internal callers, or an unauthenticated request that some earlier
/// gate already handles. Two distinct keys never share a bucket, so one key
/// exhausting its budget never starves another.
///
/// [capacity] is the burst: the most requests that can be admitted
/// back-to-back from a full bucket before the refill rate governs. [refillPeriod]
/// is the steady-state rate, expressed as the time to accrue one token — a
/// `refillPeriod` of 100ms is ten requests per second once the burst is spent.
/// Both are validated at construction: [capacity] must be `>= 1` and
/// [refillPeriod] must be strictly positive, else an [ArgumentError] is thrown
/// (an authoring defect, caught eagerly rather than silently admitting or
/// refusing everything).
///
/// ## 429 shape and Retry-After
///
/// A refusal is a `Response.json({'error': 'rate limit exceeded'}, status: 429)`
/// built directly, matching [recover]'s `{"error": ...}` body — there is no 429
/// member of the [KetaException] hierarchy, and admission control does not add
/// one. The refusal always carries a `Retry-After` header (integer seconds,
/// RFC 9110 §10.2.3) stating when the bucket will hold a token again: the wait
/// is `(1 - tokens) * refillPeriod`, rounded **up** to whole seconds so the
/// client is never told to retry before a token actually exists. The bucket can
/// state this honestly because refill is deterministic, so the header is emitted
/// unconditionally on a 429 (never a guess).
///
/// ## Memory bound against a hostile key space
///
/// An attacker-chosen key (a raw IP, a forged token) can name unlimited distinct
/// buckets, so the bucket map is not allowed to grow without bound. A bucket that
/// has refilled back to full [capacity] is byte-for-byte indistinguishable from a
/// freshly created one — dropping it changes no future decision — so such
/// buckets are evicted by an amortized sweep that runs whenever the live-bucket
/// count crosses a growing threshold (the threshold is reset to twice the number
/// of survivors after each sweep). Steady-state memory is therefore proportional
/// to the number of keys *currently being throttled* (those with a partially
/// drained bucket), not to the total number of keys ever seen; a flood of
/// single-shot keys is reclaimed on the next sweep.
///
/// ## Placement
///
/// Place `rateLimit` high in the stack — just inside [accessLog] so a 429 is
/// still logged — and, crucially, on the correct side of authentication for the
/// chosen key:
/// - keyed by **IP** (or any request-only attribute): place it **before** auth,
///   so a flood is refused before any authentication work is spent on it;
/// - keyed by **authenticated principal**: place it **after** the auth
///   middleware that establishes the principal, since [key] must be able to read
///   it. A `key` that returns `null` before the principal exists exempts the
///   request, which for a login flood is the wrong outcome — order it after auth.
///
/// See the library docs for the per-isolate multiplication under
/// `serve(isolates: n)`.
Middleware<E> rateLimit<E>({
  required Object? Function(Context<E> c) key,
  required int capacity,
  required Duration refillPeriod,
}) => RateLimiter<E>(
  key: key,
  capacity: capacity,
  refillPeriod: refillPeriod,
).middleware;

/// The token-bucket engine behind [rateLimit]. Public within the package (so a
/// white-box test can inject a clock and read [bucketCount]) but never exported;
/// user code constructs it only through the [rateLimit] factory.
class RateLimiter<E> {
  /// Builds a limiter. [clock] returns a monotonically non-decreasing time in
  /// microseconds; it defaults to a freshly started [Stopwatch] and exists as a
  /// deterministic test seam. [sweepThreshold] is the initial live-bucket count
  /// that triggers the first eviction sweep; it too is a test/tuning seam and
  /// defaults to a value no real deployment needs to touch.
  RateLimiter({
    required this.key,
    required this.capacity,
    required this.refillPeriod,
    int Function()? clock,
    int sweepThreshold = 1024,
  }) : _clock = clock ?? _startedStopwatchClock(),
       _sweepAt = sweepThreshold,
       _sweepFloor = sweepThreshold {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
    }
    if (refillPeriod <= Duration.zero) {
      throw ArgumentError.value(
        refillPeriod,
        'refillPeriod',
        'must be a positive Duration',
      );
    }
  }

  /// Maps a request to its bucket key, or `null` to exempt it. See [rateLimit].
  final Object? Function(Context<E> c) key;

  /// The burst size: the most tokens a bucket ever holds.
  final int capacity;

  /// The time to accrue one token (the steady-state rate).
  final Duration refillPeriod;

  final int Function() _clock;
  final Map<Object, _Bucket> _buckets = {};

  /// Live-bucket count that triggers the next sweep, and the floor it never
  /// drops below. The threshold grows to `2 * survivors` after each sweep, so
  /// eviction cost is amortized O(1) per request.
  int _sweepAt;
  final int _sweepFloor;

  /// The number of buckets currently held in memory. Exposed for the
  /// memory-bound test; not part of the public API.
  int get bucketCount => _buckets.length;

  static int Function() _startedStopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds;
  }

  /// The middleware view: exempts a null-keyed request, admits a request that
  /// can spend a token, and refuses the rest with a 429 + honest `Retry-After`.
  Middleware<E> get middleware => (Context<E> c, Handler<E> next) {
    final k = key(c);
    // A null key is exempt: no bucket is consulted or created (which also keeps
    // an exempt path from contributing to the key-space memory pressure).
    if (k == null) return next(c);

    final retryAfterSeconds = _consume(k);
    if (retryAfterSeconds == null) return next(c);

    // Direct 429 Response: there is no 429 KetaException and admission control
    // does not add one. Retry-After is honest — the bucket knows exactly when
    // the next token accrues.
    return Response.json(
      {'error': 'rate limit exceeded'},
      status: 429,
      headers: {
        'retry-after': ['$retryAfterSeconds'],
      },
    );
  };

  /// Tries to spend one token from [k]'s bucket. Returns `null` when a token was
  /// spent (admit); otherwise returns the whole seconds until a token will
  /// exist (refuse), always `>= 1` since a refused bucket holds `< 1` token.
  int? _consume(Object k) {
    final now = _clock();
    final perTokenMicros = refillPeriod.inMicroseconds;

    final bucket = _buckets[k];
    if (bucket == null) {
      // A brand-new key starts full, then spends one token.
      _buckets[k] = _Bucket(capacity - 1, now);
      _maybeSweep(now, perTokenMicros);
      return null;
    }

    // Refill by elapsed time, capped at capacity, then attempt to spend.
    final refilled = math.min(
      capacity.toDouble(),
      bucket.tokens + (now - bucket.lastRefill) / perTokenMicros,
    );
    if (refilled >= 1) {
      bucket
        ..tokens = refilled - 1
        ..lastRefill = now;
      _maybeSweep(now, perTokenMicros);
      return null;
    }

    // Empty: record the refilled level (so the wait is computed from it) without
    // spending, and report the honest wait until one whole token exists.
    bucket
      ..tokens = refilled
      ..lastRefill = now;
    final waitMicros = (1 - refilled) * perTokenMicros;
    return (waitMicros / Duration.microsecondsPerSecond).ceil();
  }

  /// Evicts buckets that have refilled to full [capacity] once the map has grown
  /// past [_sweepAt]. Such a bucket carries no state a fresh one would not, so
  /// dropping it is decision-preserving. The threshold is then reset to twice the
  /// survivor count (never below [_sweepFloor]), bounding steady-state memory to
  /// the set of keys actually being throttled.
  void _maybeSweep(int now, int perTokenMicros) {
    if (_buckets.length < _sweepAt) return;
    _buckets.removeWhere((_, b) {
      final refilled = b.tokens + (now - b.lastRefill) / perTokenMicros;
      return refilled >= capacity;
    });
    _sweepAt = math.max(_sweepFloor, _buckets.length * 2);
  }
}

/// One key's token bucket: a fractional token count and the clock reading at
/// which it was last refilled. Package-private mutable state.
class _Bucket {
  _Bucket(this.tokens, this.lastRefill);

  /// Tokens available, fractional so sub-token refill accrues exactly.
  double tokens;

  /// The [RateLimiter._clock] reading (microseconds) of the last refill.
  int lastRefill;
}

/// Sheds load past a concurrency ceiling: at most [maxInFlight] requests may be
/// in flight *through this middleware* at once; a request arriving while the cap
/// is full is refused immediately with `503 Service Unavailable` rather than
/// queued. [maxInFlight] must be `>= 1`, else an [ArgumentError] at construction.
///
/// ## What a "slot" covers — time-to-response, not stream lifetime
///
/// A slot is taken when the request enters and released when the handler
/// *produces its [Response]* (returns it, or throws) — **not** when a streamed
/// body finishes or an upgraded socket closes. This mirrors [timeout], which
/// bounds time-to-response and explicitly does not govern a stream's or socket's
/// lifetime: an SSE endpoint (`c.sse(...)`) and a WebSocket upgrade
/// (`Response.upgrade(...)`) both return their [Response] synchronously, so their
/// slot is released the instant that value is produced, long before the live
/// connection ends. Holding a slot for a long-lived connection's whole lifetime
/// would let a handful of idle SSE/WS clients pin every slot forever — a
/// self-inflicted denial of service — so the cap deliberately bounds concurrent
/// request *processing*, not concurrent open connections. Bound long-lived
/// connections by other means (an idle timer, a max-connections limit at the
/// transport). The slot is released on every path — success, a thrown
/// [KetaException], or any other error — so a shed or failed request never leaks
/// a slot.
///
/// ## No Retry-After
///
/// The 503 carries no `Retry-After`: a slot frees when some in-flight handler
/// completes, which this middleware cannot predict, and an honest header states
/// only what is known. (Contrast [rateLimit]'s 429, whose refill time *is*
/// known.)
///
/// ## Placement
///
/// Place `concurrencyLimit` outermost among the real-work middleware — just
/// inside [accessLog] so a shed 503 is logged — so the cap sheds before the
/// chain spends effort on a request it will drop.
///
/// See the library docs for the per-isolate multiplication under
/// `serve(isolates: n)`.
Middleware<E> concurrencyLimit<E>({required int maxInFlight}) =>
    ConcurrencyLimiter<E>(maxInFlight: maxInFlight).middleware;

/// The in-flight counter behind [concurrencyLimit]. Public within the package
/// (so a white-box test can read [inFlight]) but never exported; user code
/// constructs it only through the [concurrencyLimit] factory.
class ConcurrencyLimiter<E> {
  /// Builds a load-shedder admitting at most [maxInFlight] concurrent requests.
  ConcurrencyLimiter({required this.maxInFlight}) {
    if (maxInFlight < 1) {
      throw ArgumentError.value(maxInFlight, 'maxInFlight', 'must be >= 1');
    }
  }

  /// The maximum number of requests processed concurrently through this
  /// middleware.
  final int maxInFlight;

  int _inFlight = 0;

  /// The number of requests currently holding a slot. Exposed for the
  /// admit/refuse/release test; not part of the public API.
  int get inFlight => _inFlight;

  /// The middleware view: sheds past the cap with a 503, else admits and
  /// releases the slot exactly once when the handler produces its response or
  /// fails.
  Middleware<E> get middleware => (Context<E> c, Handler<E> next) {
    if (_inFlight >= maxInFlight) {
      // Direct 503 load-shed. No Retry-After: the free-slot time is unknowable.
      return Response.json({'error': 'server at capacity'}, status: 503);
    }

    _inFlight++;
    // Release on both settlement paths, so neither a streaming/upgrade response
    // (released when the Response value is produced) nor a thrown error leaks a
    // slot. `chain` keeps a synchronous handler synchronous.
    return guard<Response>(
      () => chain(next(c), (r) {
        _inFlight--;
        return r;
      }),
      (error, st) {
        _inFlight--;
        Error.throwWithStackTrace(error, st);
      },
    );
  };
}
