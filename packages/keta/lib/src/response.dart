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
    // Enforced unconditionally (not via assert): in a release binary an invalid
    // body would otherwise be written as a silent empty 200.
    if (body is! String && body is! List<int> && body is! Stream<List<int>>) {
      throw ArgumentError.value(body, 'body',
          'must be String, List<int>, or Stream<List<int>>');
    }
    // Reject CR/LF and other control characters in header names/values here, at
    // the semantic layer — not every Transport rejects them, and a value built
    // from user input must not carry a header-injection (response-splitting)
    // primitive past this boundary.
    for (final e in this.headers.entries) {
      if (_hasControlChar(e.key) || _hasControlChar(e.value)) {
        throw ArgumentError.value('${e.key}: ${e.value}', 'headers',
            'header name/value must not contain control characters');
      }
    }
  }

  static bool _hasControlChar(String s) {
    for (final u in s.codeUnits) {
      if (u < 0x20 || u == 0x7f) return true;
    }
    return false;
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
