library;

import 'dart:convert';

/// An HTTP response in semantic terms only: status, headers, and body.
///
/// Wire framing (Content-Length, chunked, H2/H3 frames) belongs to the
/// Transport, not here.
class Response {
  Response(this.status, {Map<String, String>? headers, this.body = ''})
    : headers = _lowerCased(headers) {
    // Enforced unconditionally (not via assert): in a release binary an invalid
    // body would otherwise be written as a silent empty 200.
    if (body is! String && body is! List<int> && body is! Stream<List<int>>) {
      throw ArgumentError.value(
        body,
        'body',
        'must be String, List<int>, or Stream<List<int>>',
      );
    }
    // Reject CR/LF and other control characters in header names/values here, at
    // the semantic layer — not every Transport rejects them, and a value built
    // from user input must not carry a header-injection (response-splitting)
    // primitive past this boundary.
    for (final e in this.headers.entries) {
      if (_hasControlChar(e.key) || _hasControlChar(e.value)) {
        throw ArgumentError.value(
          '${e.key}: ${e.value}',
          'headers',
          'header name/value must not contain control characters',
        );
      }
    }
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
  final int status;

  /// Header names are stored lower-cased for consistent lookup and merging.
  final Map<String, String> headers;

  /// One of `String`, `List<int>`, or `Stream<List<int>>`.
  final Object body;

  static bool _hasControlChar(String s) {
    for (final u in s.codeUnits) {
      if (u < 0x20 || u == 0x7f) return true;
    }
    return false;
  }

  static Map<String, String> _lowerCased(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return <String, String>{};
    return {for (final e in headers.entries) e.key.toLowerCase(): e.value};
  }
}

/// keta's exception hierarchy — everything a user throws or receives, as one
/// sealed set so an exhaustive `switch` works and there is nothing to guess.
///
/// The rule is one sentence: throw a [KetaException] subtype and the response
/// carries its [status]; every other exception (ArgumentError, StateError,
/// FormatException, …) is a defect that becomes a 500. [message] is the safe
/// user-facing text; [detail] is optional structured context (such as a
/// validation violation list) that a boundary may include or withhold.
sealed class KetaException implements Exception {
  const KetaException(this.message, [this.detail]);

  /// An arbitrary-status exception, for a code without a named subtype.
  const factory KetaException.status(
    int status,
    String message, [
    Object? detail,
  ]) = _StatusException;

  int get status;
  final String message;
  final Object? detail;

  @override
  String toString() => 'KetaException($status, $message)';
}

/// 400 — the canonical parse/validation failure.
final class BadRequest extends KetaException {
  const BadRequest(super.message, [super.detail]);
  @override
  int get status => 400;
}

/// 401.
final class Unauthorized extends KetaException {
  const Unauthorized(super.message, [super.detail]);
  @override
  int get status => 401;
}

/// 403.
final class Forbidden extends KetaException {
  const Forbidden(super.message, [super.detail]);
  @override
  int get status => 403;
}

/// 404.
final class NotFound extends KetaException {
  const NotFound(super.message, [super.detail]);
  @override
  int get status => 404;
}

/// 409.
final class Conflict extends KetaException {
  const Conflict(super.message, [super.detail]);
  @override
  int get status => 409;
}

/// 413 — `maxBodyBytes` exceeded.
final class PayloadTooLarge extends KetaException {
  const PayloadTooLarge(super.message, [super.detail]);
  @override
  int get status => 413;
}

/// 422.
final class UnprocessableEntity extends KetaException {
  const UnprocessableEntity(super.message, [super.detail]);
  @override
  int get status => 422;
}

/// 501 — scaffold stubs.
final class NotImplementedYet extends KetaException {
  const NotImplementedYet(super.message, [super.detail]);
  @override
  int get status => 501;
}

/// 503 — lockTimeout and other transient unavailability.
final class Unavailable extends KetaException {
  const Unavailable(super.message, [super.detail]);
  @override
  int get status => 503;
}

/// 504 — `timeout()`.
final class GatewayTimeout extends KetaException {
  const GatewayTimeout(super.message, [super.detail]);
  @override
  int get status => 504;
}

final class _StatusException extends KetaException {
  const _StatusException(this.status, super.message, [super.detail]);
  @override
  final int status;
}
