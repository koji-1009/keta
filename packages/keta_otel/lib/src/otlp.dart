library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';

import 'span.dart';

/// Sends an already-encoded OTLP/JSON payload somewhere. Injectable so tests
/// need no collector.
typedef OtlpSender = Future<void> Function(String jsonPayload);

/// Reports something the exporter noticed on its own, off any request's hot
/// path: a batch that failed to send, or a span-loss count discovered when
/// the queue overflowed. The signature mirrors `Log.warn`'s `(message,
/// fields)` so a caller can wire this straight to their own logger (e.g.
/// `c.log.warn`) without this package depending on `package:keta`'s `Log`
/// type. This replaces `enqueue`'s old per-call `onError` callback: once a
/// batch can hold spans from many `enqueue` calls, a failure is no longer
/// attributable to any one of them, so the seam moves to the exporter itself
/// (set once, at construction) instead.
typedef OtlpWarn = void Function(String message, Map<String, Object?> fields);

/// A minimal OTLP/HTTP exporter. It encodes spans as OTLP/JSON and hands the
/// payload to a [OtlpSender]; it depends on no external OpenTelemetry SDK.
///
/// Spans are not sent one per [enqueue] call. They accumulate in a bounded
/// queue that a periodic timer drains in batches — mirroring OTel's
/// BatchSpanProcessor defaults ([defaultMaxQueueSize] spans queued,
/// [defaultMaxBatchSize] spans per POST, [defaultExportInterval] between
/// drains). Sending one POST per served request does not survive contact
/// with a slow collector: at 1000 RPS a 10s-hanging collector accumulates
/// ~10k in-flight sockets. Batching bounds both the POST rate and the memory
/// a stalled collector can pin.
///
/// It has a lifecycle: [export]/[enqueue] register work that [flush] awaits,
/// and [close] flushes then releases resources (the HTTP client, the
/// timer). It implements keta's [Disposable] so an env that owns an exporter
/// is drained on `Server.shutdown` — call `close()` there so pending spans
/// are not dropped.
class OtlpExporter implements Disposable {
  /// [maxQueueSize]: spans queued past this many evict the oldest queued span
  /// (drop-oldest) rather than growing without bound — see [enqueue].
  /// [maxBatchSize]: the most spans placed on one POST body; a bigger
  /// backlog is drained over several batches instead of one unbounded
  /// request. [exportInterval]: how often the queue is drained absent a
  /// manual [flush] (`Duration.zero` disables the timer — draining then
  /// happens only via explicit [flush] calls). [onWarn]: see [OtlpWarn].
  OtlpExporter(
    OtlpSender send, {
    String serviceName = 'keta',
    int maxQueueSize = defaultMaxQueueSize,
    int maxBatchSize = defaultMaxBatchSize,
    Duration exportInterval = defaultExportInterval,
    OtlpWarn? onWarn,
  }) : this._(
         send,
         serviceName,
         null,
         maxQueueSize: maxQueueSize,
         maxBatchSize: maxBatchSize,
         exportInterval: exportInterval,
         onWarn: onWarn,
       );

  OtlpExporter._(
    this._send,
    this.serviceName,
    this._releaseResources, {
    required this.maxQueueSize,
    required this.maxBatchSize,
    required Duration exportInterval,
    Completer<void>? closing,
    this._onWarn,
  }) : _closing = closing ?? Completer<void>() {
    if (exportInterval > Duration.zero) {
      _timer = Timer.periodic(exportInterval, (_) => _drainNextBatch());
    }
  }

  /// An exporter that POSTs to an OTLP/HTTP `v1/traces` [endpoint]. A non-2xx
  /// response is treated as a failure (so a persistently-down collector is
  /// visible via [onWarn]), and the underlying [HttpClient] is released by
  /// [close].
  ///
  /// The whole request/response cycle of each POST is bounded by [timeout]
  /// (default 10s): a collector that accepts the connection and never
  /// responds cannot hang `flush()`/`close()` (the latter runs inside server
  /// shutdown). A timeout surfaces as a [TimeoutException], the same
  /// failed-batch path as any other send error, and also `abort()`s the
  /// in-flight request — a bare `Future.timeout` only gives up on waiting,
  /// it does not tell the socket to stop, so without the abort a dead
  /// collector accumulates one ESTABLISHED connection per timed-out export
  /// forever. [close] also force-closes the client so a still-open
  /// connection at shutdown (flush already ran; anything left is exactly
  /// the stuck kind) is not left dangling either. This per-POST protection
  /// is orthogonal to batching above it: batching changes when a POST is
  /// made, not how each individual POST is guarded.
  ///
  /// The *gap* between retryable attempts is bounded separately from the
  /// per-POST [timeout]. A retryable response (429/503) may carry a
  /// `Retry-After`; that value is attacker/collector-controlled, so the
  /// honored delay is clamped to [maxRetryDelay] — an absurd `Retry-After`
  /// (`2000000000`, a 63-year sleep) can never park a batch, and thus
  /// `flush()`/`close()`, for longer than that cap. On top of the clamp, each
  /// retry sleep races the exporter's own shutdown signal: [close] fires it
  /// before awaiting in-flight work, so a batch parked in a retry sleep is cut
  /// loose immediately instead of holding shutdown for the (already bounded)
  /// remaining delay. Together these keep the whole retry loop — attempts and
  /// sleeps alike — bounded in wall-clock time regardless of collector
  /// behavior.
  factory OtlpExporter.http(
    Uri endpoint, {
    String serviceName = 'keta',
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = defaultMaxRetries,
    Duration retryBackoff = defaultRetryBackoff,
    Duration maxRetryDelay = defaultMaxRetryDelay,
    int maxQueueSize = defaultMaxQueueSize,
    int maxBatchSize = defaultMaxBatchSize,
    Duration exportInterval = defaultExportInterval,
    OtlpWarn? onWarn,
  }) {
    final client = HttpClient();
    // Completed by `close()` the instant shutdown begins (before it awaits
    // in-flight work). Retry sleeps race this so a mid-retry batch bails
    // promptly rather than pinning `flush()` for its remaining delay. Shared
    // with the instance below via the private constructor's `closing:`.
    final closing = Completer<void>();

    // One POST attempt, guarded by [timeout]. Returns the delay to wait before
    // retrying when the collector answered with a *retryable* status (429/503)
    // — honoring its `Retry-After` (delta-seconds) when present, else
    // [retryBackoff]; returns null on a 2xx success; throws on a terminal
    // failure (any other non-2xx, or a transport/timeout error).
    //
    // `Future.timeout` on its own only abandons the *Future*: the collector
    // side's socket stays ESTABLISHED forever because nothing ever tells the
    // underlying HttpClientRequest to stop waiting for a response. This keeps a
    // handle to the in-flight request so a timeout can `abort()` it — which is
    // what actually tears down the socket — in addition to surfacing the same
    // TimeoutException a bare `.timeout()` would. The original `pending` future
    // is `ignore()`d once aborted: `abort()` completes it with an error
    // asynchronously, after the returned future has already completed via
    // `onTimeout`, so nothing is left to observe it — without `ignore()` that
    // would surface as an unhandled async error.
    Future<Duration?> attempt(String payload) {
      HttpClientRequest? request;
      final pending = () async {
        request = await client.postUrl(endpoint);
        request!.headers.contentType = ContentType.json;
        headers.forEach(request!.headers.set);
        request!.add(utf8.encode(payload));
        final response = await request!.close();
        final retryAfter = response.headers.value('retry-after');
        await response.drain<void>();
        final status = response.statusCode;
        if (status >= 200 && status < 300) return null;
        // 429 (Too Many Requests) and 503 (Service Unavailable) are the
        // collector saying "not now" — retryable. Every other non-2xx (a 4xx
        // config/auth error, a 500) is terminal: re-POSTing the same body just
        // earns the same rejection, so it fails the batch immediately.
        if (status == 429 || status == 503) {
          return _retryDelay(retryAfter, retryBackoff, maxRetryDelay);
        }
        throw HttpException('OTLP export rejected: HTTP $status');
      }();
      return pending.timeout(
        timeout,
        onTimeout: () {
          request?.abort();
          pending.ignore();
          throw TimeoutException('OTLP export timed out after $timeout');
        },
      );
    }

    // Bounded retry loop: at most [maxRetries] retries after the first attempt,
    // so a collector that is briefly overloaded (429) or restarting (503) does
    // not cost the batch, while a persistently-unavailable one still gives up
    // after a fixed number of tries rather than retrying forever.
    //
    // Retrying happens *here*, inside the single send — the batch is not
    // re-queued at the front. That is the bounded-memory choice: a retrying
    // batch holds only its own (<= maxBatchSize) spans for the duration of its
    // bounded attempts, and because `_drainNextBatch` tracks this future
    // without awaiting it, the periodic timer keeps draining *newer* batches
    // from the queue meanwhile — a stuck collector delays only its own batch,
    // never the ones behind it, and the queue stays capped at maxQueueSize with
    // drop-oldest regardless. Re-queuing at the front would instead let one
    // unlucky batch head-of-line-block every newer span behind it.
    Future<void> post(String payload) async {
      for (var remaining = maxRetries; ; remaining--) {
        final delay = await attempt(payload);
        if (delay == null) return; // 2xx: sent.
        if (remaining == 0) {
          // Out of retries: surface the same failure shape any other rejected
          // send has, so `_drainNextBatch` counts the batch as dropped and
          // folds it into the deferred drop report.
          throw HttpException(
            'OTLP export still retryable after ${maxRetries + 1} attempts',
          );
        }
        // Wait out the (already [maxRetryDelay]-clamped) delay, but abandon it
        // the moment `close()` fires `closing`: this is what keeps `close()`
        // bounded when a batch is mid-retry-sleep. Abandoning throws the same
        // failure shape a rejected send does, so `_drainNextBatch` folds the
        // batch into the drop count rather than losing it silently.
        if (await _sleepUnless(delay, closing.future)) {
          throw StateError('OTLP export abandoned: exporter closing');
        }
      }
    }

    return OtlpExporter._(
      post,
      serviceName,
      () => client.close(force: true),
      maxQueueSize: maxQueueSize,
      maxBatchSize: maxBatchSize,
      exportInterval: exportInterval,
      closing: closing,
      onWarn: onWarn,
    );
  }

  /// Mirrors OTel's BatchSpanProcessor `maxQueueSize` default.
  static const int defaultMaxQueueSize = 2048;

  /// Mirrors OTel's BatchSpanProcessor `maxExportBatchSize` default.
  static const int defaultMaxBatchSize = 512;

  /// Mirrors OTel's BatchSpanProcessor `scheduledDelayMillis` default.
  static const Duration defaultExportInterval = Duration(seconds: 5);

  /// Retries after the first attempt for a retryable (429/503) response — three
  /// total tries. Bounded so a persistently-down collector gives up rather than
  /// retrying a doomed batch forever.
  static const int defaultMaxRetries = 2;

  /// The backoff between retryable attempts when the collector sends no
  /// `Retry-After` to override it.
  static const Duration defaultRetryBackoff = Duration(milliseconds: 500);

  /// The ceiling on a *honored* `Retry-After`. The header is collector- (and
  /// so, for a compromised collector, attacker-) controlled, so its value is
  /// clamped to this before it can park a batch: 5s is a small multiple of
  /// [defaultRetryBackoff] and stays under the per-POST `timeout`, keeping a
  /// batch's total retry time — and thus how long `flush()`/`close()` can wait
  /// on it — on the order of one request rather than unbounded. The operator's
  /// own `retryBackoff` fallback is trusted and never clamped.
  static const Duration defaultMaxRetryDelay = Duration(seconds: 5);

  final OtlpSender _send;
  final String serviceName;
  final int maxQueueSize;
  final int maxBatchSize;
  final void Function()? _releaseResources;
  final OtlpWarn? _onWarn;
  final Set<Future<void>> _inFlight = {};

  /// The bounded export queue [enqueue] appends to and [_drainNextBatch]
  /// drains from, oldest-first.
  final ListQueue<OtelSpan> _queue = ListQueue<OtelSpan>();

  /// Spans lost since the last report: either evicted by [enqueue] to keep
  /// the queue within [maxQueueSize], or lost because the batch containing
  /// them failed to send. Reported via [_onWarn] the next time a batch
  /// export *succeeds* — never reset by a failed export, so a report is
  /// deferred, not dropped (the same discipline as keta core's log
  /// backlog: losing data beats losing the server, but losing it silently
  /// is not on the menu).
  int _dropped = 0;

  /// Completed by [close] the moment shutdown begins, before it awaits
  /// in-flight work. The `OtlpExporter.http` sender's retry sleeps race this,
  /// so a batch parked mid-retry is cut loose promptly instead of holding
  /// [flush]/[close] for its remaining (already clamped) delay.
  final Completer<void> _closing;

  Timer? _timer;

  /// Encodes and sends [spans] immediately, bypassing the queue, returning a
  /// future that completes when the send finishes (or rejects on failure).
  /// Tracked so [flush] can await it. Use this for a one-off, directly
  /// observed send; [enqueue] is the batched path everything else goes
  /// through.
  Future<void> export(List<OtelSpan> spans) {
    if (spans.isEmpty) return Future.value();
    return _track(_send(jsonEncode(encodeOtlp(spans, serviceName))));
  }

  /// Appends [spans] to the bounded export queue. Actual sending happens
  /// later — on [exportInterval]'s timer or when [flush] is called — so
  /// this is a synchronous queue append, never a network call: it costs
  /// nothing on the caller's hot path regardless of collector health.
  ///
  /// Past [maxQueueSize] the oldest queued span is evicted to admit each new
  /// one (drop-oldest): a stalled collector must not let the queue, and so
  /// memory, grow without bound. The eviction is never silent — see
  /// [_dropped].
  void enqueue(List<OtelSpan> spans) {
    for (final span in spans) {
      if (_queue.length >= maxQueueSize) {
        _queue.removeFirst();
        _dropped++;
      }
      _queue.add(span);
    }
  }

  /// Sends the next single batch (up to [maxBatchSize] spans) if the queue
  /// is non-empty, tracked so [flush] can await it. Called by the periodic
  /// timer and, in a loop, by [flush] — same primitive, two callers.
  void _drainNextBatch() {
    if (_queue.isEmpty) return;
    final batch = <OtelSpan>[];
    while (batch.length < maxBatchSize && _queue.isNotEmpty) {
      batch.add(_queue.removeFirst());
    }
    // Snapshot-and-clear before the send, mirroring `_Backlog._drain`: a
    // report that lands is reported exactly once, and one that doesn't
    // (the send below fails) is folded back rather than lost — see the
    // catchError branch.
    final droppedNow = _dropped;
    _dropped = 0;
    // Wrapped in an `async` body (rather than chaining `.then`/`.catchError`
    // straight off `_send(...)`'s call expression) so a sender that throws
    // *synchronously* — never returning a Future at all — is caught here
    // too, the same as a sender that returns a rejected Future. Without
    // this, a synchronously-throwing sender would blow up `flush()`/`close()`
    // itself instead of being reported through [_onWarn].
    final Future<void> future = () async {
      try {
        await _send(jsonEncode(encodeOtlp(batch, serviceName)));
        if (droppedNow > 0) {
          _onWarn?.call('OTLP spans dropped', {'dropped': droppedNow});
        }
      } catch (error) {
        // This batch didn't land either, so its spans are lost the same way
        // a drop-oldest eviction is. Folding their count in with any pending
        // drop report (rather than reporting only the eviction count and
        // silently eating the failed batch) keeps the total loss visible at
        // the next successful export.
        _dropped += droppedNow + batch.length;
        _onWarn?.call('span export failed', {'error': '$error'});
      }
    }();
    _track(future);
  }

  Future<void> _track(Future<void> future) {
    _inFlight.add(future);
    future.whenComplete(() => _inFlight.remove(future)).catchError((_) {});
    return future;
  }

  /// Drains the export queue fully — every batch, including spans [enqueue]d
  /// mid-flush — and awaits every export in flight, looping until both are
  /// quiescent. Call before shutdown so pending spans land.
  ///
  /// Looping (rather than one pass over a snapshot) is what makes "drains
  /// spans enqueued mid-flush" true: a snapshot would miss a span appended
  /// while this wait is already in progress — e.g. a request still finishing
  /// during shutdown's drain window. It stays bounded because every export is
  /// bounded in wall-clock time: each POST races the sender's own per-POST
  /// timeout, and each inter-attempt retry sleep is clamped to `maxRetryDelay`
  /// over a bounded number of retries (see `OtlpExporter.http`). So a stuck or
  /// hostile collector — even one answering 429/503 with a giant `Retry-After`
  /// — cannot make this loop run indefinitely; only requests that keep
  /// enqueuing new spans forever can. When the caller is [close] rather than a
  /// standalone `flush()`, the `_closing` signal additionally cuts any batch
  /// mid-retry-sleep, so shutdown does not even wait out the clamped delay.
  Future<void> flush() async {
    while (_queue.isNotEmpty || _inFlight.isNotEmpty) {
      while (_queue.isNotEmpty) {
        _drainNextBatch();
      }
      if (_inFlight.isNotEmpty) {
        await Future.wait(_inFlight.toList()).then((_) {}).catchError((_) {});
      }
    }
  }

  /// Flushes, then cancels the periodic timer and releases resources (the
  /// HTTP client). The timer must never outlive `close()` — a periodic
  /// `Timer` pins its isolate open, so a leaked one keeps a shut-down server
  /// process from exiting. Safe to call from `Server.shutdown` via
  /// [Disposable].
  ///
  /// The `_closing` signal is fired *before* the flush: a batch parked in a
  /// retry sleep is racing that signal (see `OtlpExporter.http`), so firing it
  /// first cuts such a batch loose immediately — otherwise `flush()`'s
  /// `Future.wait` would block on the sleeping batch future for its remaining
  /// (clamped) delay. A cut batch fails like any other, so its spans are
  /// counted as dropped. This is what makes `close()` bounded regardless of
  /// how a collector answers.
  @override
  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await flush();
    _timer?.cancel();
    _releaseResources?.call();
  }
}

/// The delay to wait before a retryable re-POST: the collector's `Retry-After`
/// when it is a non-negative delta-seconds count, else [fallback].
///
/// Only the numeric delta-seconds form (RFC 9110 §10.2.3) is honored, not the
/// HTTP-date form: a collector throttling a client uses seconds in practice, and
/// a bogus or date value simply falls back to the fixed backoff rather than
/// failing the send.
///
/// The honored header value is clamped to [maxDelay]. `Retry-After` is
/// collector-controlled, and a hostile or compromised collector answering
/// 429/503 with a huge count (`2000000000` → a 63-year `Duration`) must not be
/// able to park a batch — and, through it, `flush()`/`close()` — for that long.
/// [fallback] is the operator's own configured backoff, trusted, so it is used
/// as-is without clamping.
Duration _retryDelay(String? retryAfter, Duration fallback, Duration maxDelay) {
  final seconds = retryAfter == null ? null : int.tryParse(retryAfter.trim());
  if (seconds != null && seconds >= 0) {
    final honored = Duration(seconds: seconds);
    return honored > maxDelay ? maxDelay : honored;
  }
  return fallback;
}

/// Sleeps for [delay], unless [abort] completes first. Returns `true` if
/// [abort] won the race (the caller should give up), `false` if the full delay
/// elapsed.
///
/// A bare `Future.delayed` cannot be cancelled, so a plain `Future.any` race
/// would leave its timer running until [delay] elapses even after [abort] won —
/// harmless per call, but this is the exporter's shutdown path, where the point
/// is to *stop* waiting. Driving an explicit [Timer] lets the [abort] branch
/// cancel it, so a shutdown truly ends the sleep then and there rather than
/// merely ignoring its result.
Future<bool> _sleepUnless(Duration delay, Future<void> abort) {
  final done = Completer<bool>();
  final timer = Timer(delay, () {
    if (!done.isCompleted) done.complete(false);
  });
  abort.then((_) {
    if (!done.isCompleted) {
      timer.cancel();
      done.complete(true);
    }
  });
  return done.future;
}

/// Encodes [spans] into an OTLP/JSON `ExportTraceServiceRequest` body.
Map<String, Object?> encodeOtlp(List<OtelSpan> spans, String serviceName) => {
  'resourceSpans': [
    {
      'resource': {
        'attributes': [_attribute('service.name', serviceName)],
      },
      'scopeSpans': [
        {
          'scope': {'name': 'keta_otel'},
          'spans': [for (final span in spans) _encodeSpan(span)],
        },
      ],
    },
  ],
};

Map<String, Object?> _encodeSpan(OtelSpan span) => {
  'traceId': span.traceId,
  'spanId': span.spanId,
  if (span.parentSpanId != null) 'parentSpanId': span.parentSpanId,
  'name': span.name,
  'kind': 2, // SPAN_KIND_SERVER
  'startTimeUnixNano': '${span.startUnixNano}',
  'endTimeUnixNano': '${span.endUnixNano}',
  'attributes': [
    for (final entry in span.attributes.entries)
      _attribute(entry.key, entry.value),
  ],
  'status': {'code': span.status.index},
};

Map<String, Object?> _attribute(String key, Object? value) => {
  'key': key,
  'value': switch (value) {
    String() => {'stringValue': value},
    bool() => {'boolValue': value},
    int() => {'intValue': '$value'},
    double() => {'doubleValue': value},
    _ => {'stringValue': '$value'},
  },
};
