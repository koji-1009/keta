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
    this._onWarn,
  }) {
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
  factory OtlpExporter.http(
    Uri endpoint, {
    String serviceName = 'keta',
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
    int maxQueueSize = defaultMaxQueueSize,
    int maxBatchSize = defaultMaxBatchSize,
    Duration exportInterval = defaultExportInterval,
    OtlpWarn? onWarn,
  }) {
    final client = HttpClient();

    // `Future.timeout` on its own only abandons the *Future*: the collector
    // side's socket stays ESTABLISHED forever because nothing ever tells the
    // underlying HttpClientRequest to stop waiting for a response. `post`
    // keeps a handle to the in-flight request so a timeout can `abort()` it
    // — which is what actually tears down the socket — in addition to
    // surfacing the same TimeoutException a bare `.timeout()` would. The
    // original `pending` future is `ignore()`d once aborted: `abort()`
    // completes it with an error asynchronously, after the returned future
    // has already completed via `onTimeout`, so nothing is left to observe
    // it — without `ignore()` that would surface as an unhandled async
    // error.
    Future<void> post(String payload) {
      HttpClientRequest? request;
      final pending = () async {
        request = await client.postUrl(endpoint);
        request!.headers.contentType = ContentType.json;
        headers.forEach(request!.headers.set);
        request!.add(utf8.encode(payload));
        final response = await request!.close();
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'OTLP export rejected: HTTP ${response.statusCode}',
          );
        }
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

    return OtlpExporter._(
      post,
      serviceName,
      () => client.close(force: true),
      maxQueueSize: maxQueueSize,
      maxBatchSize: maxBatchSize,
      exportInterval: exportInterval,
      onWarn: onWarn,
    );
  }

  /// Mirrors OTel's BatchSpanProcessor `maxQueueSize` default.
  static const int defaultMaxQueueSize = 2048;

  /// Mirrors OTel's BatchSpanProcessor `maxExportBatchSize` default.
  static const int defaultMaxBatchSize = 512;

  /// Mirrors OTel's BatchSpanProcessor `scheduledDelayMillis` default.
  static const Duration defaultExportInterval = Duration(seconds: 5);

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
  /// while this wait is already in progress — e.g. a request still
  /// finishing during shutdown's drain window. It stays bounded because
  /// each export races the sender's own timeout (see `OtlpExporter.http`),
  /// so a stuck collector cannot make this loop over indefinitely, only
  /// requests that keep enqueuing new spans forever can.
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
  @override
  Future<void> close() async {
    await flush();
    _timer?.cancel();
    _releaseResources?.call();
  }
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
