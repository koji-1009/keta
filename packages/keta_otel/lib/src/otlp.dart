library;

import 'dart:convert';
import 'dart:io';

import 'span.dart';

/// Sends an already-encoded OTLP/JSON payload somewhere. Injectable so tests
/// need no collector.
typedef OtlpSender = Future<void> Function(String jsonPayload);

/// A minimal OTLP/HTTP exporter. It encodes spans as OTLP/JSON and hands the
/// payload to a [OtlpSender]; it depends on no external OpenTelemetry SDK.
class OtlpExporter {
  final OtlpSender _send;
  final String serviceName;

  OtlpExporter(this._send, {this.serviceName = 'keta'});

  /// An exporter that POSTs to an OTLP/HTTP `v1/traces` [endpoint].
  factory OtlpExporter.http(
    Uri endpoint, {
    String serviceName = 'keta',
    Map<String, String> headers = const {},
  }) {
    final client = HttpClient();
    return OtlpExporter(
      (payload) async {
        final request = await client.postUrl(endpoint);
        request.headers.contentType = ContentType.json;
        headers.forEach(request.headers.set);
        request.add(utf8.encode(payload));
        final response = await request.close();
        await response.drain<void>();
      },
      serviceName: serviceName,
    );
  }

  Future<void> export(List<OtelSpan> spans) {
    if (spans.isEmpty) return Future.value();
    return _send(jsonEncode(encodeOtlp(spans, serviceName)));
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
