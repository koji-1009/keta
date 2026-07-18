library;

import 'dart:async';
import 'dart:convert';

import 'upgrade.dart';

/// Stateless across calls (`convert` builds its own state each time), so one
/// instance is shared. The default 256-byte buffer is kept on purpose: measured
/// against 1KiB/4KiB/16KiB, a larger buffer gains ~3% on an 8.9KB body while
/// costing ~49% on a 111-byte one, which is the shape most responses have.
final _jsonUtf8 = JsonUtf8Encoder();

/// An HTTP response in semantic terms only: status, headers, and body.
///
/// Wire framing (Content-Length, chunked, H2/H3 frames) belongs to the
/// Transport, not here.
class Response {
  Response(
    this.status, {
    Map<String, List<String>>? headers,
    this.body = '',
    this.upgrade,
  }) : headers = _normalize(headers) {
    // Enforced unconditionally (not via assert): in a release binary an invalid
    // body would otherwise be written as a silent empty 200.
    if (body is! String && body is! List<int> && body is! Stream<List<int>>) {
      throw ArgumentError.value(
        body,
        'body',
        'must be String, List<int>, or Stream<List<int>>',
      );
    }
    // An upgrade response answers by switching protocols: its status is fixed at
    // 101 and it carries no body (the switched protocol carries the bytes). A
    // mismatched status/body here is an authoring defect, caught at the semantic
    // layer before any transport tries — and fails — to realize it.
    if (upgrade != null) {
      if (status != 101) {
        throw ArgumentError.value(
          status,
          'status',
          'an upgrade response must have status 101 (switching protocols)',
        );
      }
      if (body is! String || (body as String).isNotEmpty) {
        throw ArgumentError.value(
          body,
          'body',
          'an upgrade response carries no body',
        );
      }
    }
    // Reject CR/LF and other control characters in header names/values here, at
    // the semantic layer — not every Transport rejects them, and a value built
    // from user input must not carry a header-injection (response-splitting)
    // primitive past this boundary.
    for (final e in this.headers.entries) {
      if (_hasControlChar(e.key)) {
        throw ArgumentError.value(
          e.key,
          'headers',
          'header name must not contain control characters',
        );
      }
      for (final value in e.value) {
        // A field value may carry HTAB (RFC 9110 §5.5: field-value allows
        // HTAB alongside VCHAR/SP); only CR/LF and the other controls are the
        // response-splitting primitive to reject.
        if (_hasControlChar(value, allowTab: true)) {
          throw ArgumentError.value(
            value,
            'headers',
            'header value must not contain control characters',
          );
        }
      }
    }
  }

  /// A JSON response encoded straight to UTF-8 bytes, with `application/json`.
  /// [headers] merge over the content type (which they may override).
  ///
  /// Deliberately not `jsonEncode`: that builds a UTF-16 [String] which the
  /// Transport then re-walks with `utf8.encode` and discards. The String is
  /// never wanted, so producing it is pure waste — [JsonUtf8Encoder] writes the
  /// bytes the socket needs in one pass. The output is byte-identical, and the
  /// default `toEncodable` (`object.toJson()`) is the same for both.
  factory Response.json(
    Object? body, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => Response(
    status,
    headers: {
      'content-type': const ['application/json; charset=utf-8'],
      ...?headers,
    },
    body: _jsonUtf8.convert(body),
  );

  /// A `text/plain; charset=utf-8` response. [headers] merge over the content
  /// type (which they may override).
  factory Response.text(
    String body, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => Response(
    status,
    headers: {
      'content-type': const ['text/plain; charset=utf-8'],
      ...?headers,
    },
    body: body,
  );

  /// A response that answers by *upgrading* the connection — the value form of
  /// "this route replies with 101 Switching Protocols and then speaks another
  /// protocol." [onConnected] is handed the switched [UpgradedChannel] once (and
  /// only if) a transport that can perform the switch acts on this value; until
  /// then it is inert data. Because this is an ordinary return value, every
  /// declaration-driven middleware runs in front of it — a security gate returns
  /// a plain 401 and this value is never even built.
  ///
  /// [subprotocol], when given, is the WebSocket subprotocol to negotiate; the
  /// client must have offered it.
  ///
  /// A transport that cannot switch protocols must reject this loudly (the shelf
  /// bridge raises a `StateError`; `TestClient` routes it to an in-process
  /// channel or a rejection). Handshake response headers belong to the
  /// realizing transport, not to this value, so none are accepted here.
  factory Response.upgrade(
    FutureOr<void> Function(UpgradedChannel channel) onConnected, {
    String? subprotocol,
  }) => Response(101, upgrade: Upgrade(onConnected, subprotocol: subprotocol));

  /// Returns a copy with only the named fields replaced; every field left
  /// unnamed — including [upgrade] — is carried over unchanged.
  ///
  /// This is the one sanctioned way for a middleware to rebuild a response, and
  /// the invariant it exists to hold is structural: a middleware that only means
  /// to touch the headers ([cors]) or the body ([gzip]) must never be able to
  /// *silently* strip a semantic field it did not name. A fresh `Response(...)`
  /// drops whatever the constructor call omits — which is exactly how an
  /// app-wide `cors` once answered a WebSocket handshake with 101 yet never
  /// switched, because rebuilding the response for its merged headers left
  /// [upgrade] behind. Routing every rebuild through here makes that class of
  /// bug impossible by construction: any field added to [Response] in future is
  /// preserved by default, so a new rebuild site cannot omit it out of ignorance
  /// of its existence. The constructor's invariants (the 101/empty-body upgrade
  /// guard, header control-char rejection) re-run on the copy, so a rebuild that
  /// *would* violate them — e.g. handing an upgrade response a body — throws
  /// rather than producing a malformed value.
  Response copyWith({
    int? status,
    Map<String, List<String>>? headers,
    Object? body,
  }) => Response(
    status ?? this.status,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    upgrade: upgrade,
  );
  final int status;

  /// Header names are lower-cased; each maps to its ordered values (multi-value,
  /// so multiple `set-cookie` etc. are faithful).
  final Map<String, List<String>> headers;

  /// One of `String`, `List<int>`, or `Stream<List<int>>`.
  final Object body;

  /// Non-null when this response answers by switching protocols instead of
  /// returning [body]: the realizing transport reads it, performs the handshake,
  /// and invokes its `onConnected`. Null for every ordinary response — the
  /// discriminator a transport keys off to choose the upgrade path. See
  /// `Response.upgrade`.
  final Upgrade? upgrade;

  static bool _hasControlChar(String s, {bool allowTab = false}) {
    for (final u in s.codeUnits) {
      if (allowTab && u == 0x09) continue; // HTAB is legal in a field value
      if (u < 0x20 || u == 0x7f) return true;
    }
    return false;
  }

  static Map<String, List<String>> _normalize(
    Map<String, List<String>>? headers,
  ) {
    if (headers == null || headers.isEmpty) return const {};
    return {
      for (final e in headers.entries) e.key.toLowerCase(): List.of(e.value),
    };
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

/// 503 — the operation raced or deadlocked and retrying the *same* request is a
/// reasonable next move (a serialization failure or a deadlock the engine broke
/// by aborting this transaction). The retryability is the type: there is no
/// `retryable` flag and no `Retryable` marker — a caller keys off `is
/// TransientFailure`, and the exhaustive `switch` over [KetaException] makes the
/// case impossible to forget.
///
/// keta deliberately does NOT retry for you. Whether replaying the request is
/// safe depends on its idempotency, which is unknowable at this layer (the same
/// R-12 posture the disconnect path takes — an in-flight query is never
/// silently re-run). [TransientFailure] exists so the *application*, which does
/// know whether the operation is safe to repeat, can decide to retry.
///
/// Distinct from [Unavailable], though both are 503: [Unavailable] means the
/// database could not be reached or served the request at all (unreachable
/// server, exhausted pool, a lock never taken) — nothing happened and the
/// system is momentarily unusable. [TransientFailure] means the request *did*
/// reach a working database and lost a concurrency race there; the system is
/// healthy and the very same request may well succeed on a second try.
final class TransientFailure extends KetaException {
  const TransientFailure(super.message, [super.detail]);
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
