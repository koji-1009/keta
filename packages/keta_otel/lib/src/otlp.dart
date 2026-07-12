library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';

import 'span.dart';

/// Sends an already-encoded OTLP/JSON payload somewhere. Injectable so tests
/// need no collector.
typedef OtlpSender = Future<void> Function(String jsonPayload);

/// A minimal OTLP/HTTP exporter. It encodes spans as OTLP/JSON and hands the
/// payload to a [OtlpSender]; it depends on no external OpenTelemetry SDK.
///
/// It has a lifecycle: [export]/[enqueue] register in-flight sends that [flush]
/// awaits, and [close] flushes then releases resources (the HTTP client). It
/// implements keta's [Disposable] so an env that owns an exporter is drained on
/// `Server.shutdown` — call `close()` there so pending spans are not dropped.
class OtlpExporter implements Disposable {
  OtlpExporter(this._send, {this.serviceName = 'keta'})
    : _releaseResources = null;

  OtlpExporter._(this._send, this.serviceName, this._releaseResources);

  /// An exporter that POSTs to an OTLP/HTTP `v1/traces` [endpoint]. A non-2xx
  /// response is treated as a failure (so a persistently-down collector is
  /// visible to the caller), and the underlying [HttpClient] is released by
  /// [close].
  factory OtlpExporter.http(
    Uri endpoint, {
    String serviceName = 'keta',
    Map<String, String> headers = const {},
  }) {
    final client = HttpClient();
    return OtlpExporter._(
      (payload) async {
        final request = await client.postUrl(endpoint);
        request.headers.contentType = ContentType.json;
        headers.forEach(request.headers.set);
        request.add(utf8.encode(payload));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'OTLP export rejected: HTTP ${response.statusCode}',
          );
        }
      },
      serviceName,
      client.close,
    );
  }
  final OtlpSender _send;
  final String serviceName;
  final void Function()? _releaseResources;
  final Set<Future<void>> _inFlight = {};

  /// Encodes and sends [spans], returning a future that completes when the send
  /// finishes. Tracked so [flush] can await it.
  Future<void> export(List<OtelSpan> spans) {
    if (spans.isEmpty) return Future.value();
    return _track(_send(jsonEncode(encodeOtlp(spans, serviceName))));
  }

  /// Fire-and-forget export scheduled OFF the caller's hot path: the encode and
  /// send run in a later event-loop task, never on the response path. Failures
  /// go to [onError] (never to the caller). Tracked so [flush] awaits it.
  void enqueue(
    List<OtelSpan> spans, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    if (spans.isEmpty) return;
    final completer = Completer<void>();
    _inFlight.add(completer.future);
    completer.future.catchError((_) {}); // never an unhandled rejection
    Future<void>(() async {
      try {
        await _send(jsonEncode(encodeOtlp(spans, serviceName)));
      } catch (e, st) {
        onError?.call(e, st);
      } finally {
        _inFlight.remove(completer.future);
        completer.complete();
      }
    });
  }

  Future<void> _track(Future<void> future) {
    _inFlight.add(future);
    future.whenComplete(() => _inFlight.remove(future)).catchError((_) {});
    return future;
  }

  /// Awaits every in-flight export. Call before shutdown so pending spans land.
  Future<void> flush() =>
      Future.wait(_inFlight.toList()).then((_) {}).catchError((_) {});

  /// Flushes, then releases resources (the HTTP client). Idempotent-ish; safe to
  /// call from `Server.shutdown` via [Disposable].
  @override
  Future<void> close() async {
    await flush();
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
