library;

import 'dart:convert';

/// An HTTP response in semantic terms only: status, headers, and body.
///
/// Wire framing (Content-Length, chunked, H2/H3 frames) belongs to the
/// Transport, not here.
class Response {
  final int status;

  /// Header names are stored lower-cased for consistent lookup and merging.
  final Map<String, String> headers;

  /// One of `String`, `List<int>`, or `Stream<List<int>>`.
  final Object body;

  Response(this.status, {Map<String, String>? headers, this.body = ''})
      : headers = _lowerCased(headers) {
    assert(
      body is String || body is List<int> || body is Stream<List<int>>,
      'Response body must be String | List<int> | Stream<List<int>>, '
      'got ${body.runtimeType}',
    );
  }

  static Map<String, String> _lowerCased(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return <String, String>{};
    return {
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
    };
  }

  /// A JSON response: `jsonEncode(body)` with `application/json`.
  factory Response.json(Object? body, [int status = 200]) => Response(
        status,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode(body),
      );

  /// A `text/plain; charset=utf-8` response.
  factory Response.text(String body, [int status = 200]) => Response(
        status,
        headers: const {'content-type': 'text/plain; charset=utf-8'},
        body: body,
      );
}

/// The framework's single exception type.
///
/// [status] is the HTTP status to surface, [message] the safe user-facing
/// text, and [detail] optional structured context (such as a validation
/// violation list) that a boundary may choose to include or withhold.
class KetaException implements Exception {
  final int status;
  final String message;
  final Object? detail;

  const KetaException(this.status, this.message, [this.detail]);

  @override
  String toString() => 'KetaException($status, $message)';
}
