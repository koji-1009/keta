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
    _checkBody(status, body, upgrade);
    // Reject CR/LF and other control characters in header names/values here, at
    // the semantic layer — not every Transport rejects them, and a value built
    // from user input must not carry a header-injection (response-splitting)
    // primitive past this boundary.
    _rejectControlChars(this.headers);
  }

  /// A copy over already-normalized, already-validated header state. The header
  /// gate (lower-casing, list-copying, control-char rejection) is deliberately
  /// skipped, so this is ONLY reachable from header state that already passed
  /// the public gate: [copyWith] carrying `this.headers` unchanged, merging
  /// freshly-validated additions over it, or a wholesale replacement that was
  /// itself just normalized and scanned. The body/upgrade invariants are NOT
  /// header state — [status] and [body] can change across a copy — so they DO
  /// re-run here: a copy that would hand an upgrade response a body, or move it
  /// off 101, still throws rather than mint a malformed value.
  Response._trusted(this.status, this.headers, this.body, this.upgrade) {
    _checkBody(status, body, upgrade);
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
  /// [maxIdle] and [maxLifetime] are E-21a's opt-in lifetime bounds on the
  /// switched connection — see [Upgrade.maxIdle] and [Upgrade.maxLifetime] for
  /// their exact semantics (what resets the idle clock, the close code used on
  /// expiry). Both null by default: no bound, current behavior unchanged.
  /// Non-positive values throw [ArgumentError] (an authoring defect).
  ///
  /// A transport that cannot switch protocols must reject this loudly
  /// (`TestClient` routes it to an in-process channel or a rejection).
  /// Handshake response headers belong to the
  /// realizing transport, not to this value, so none are accepted here.
  factory Response.upgrade(
    FutureOr<void> Function(UpgradedChannel channel) onConnected, {
    String? subprotocol,
    Duration? maxIdle,
    Duration? maxLifetime,
  }) => Response(
    101,
    upgrade: Upgrade(
      onConnected,
      subprotocol: subprotocol,
      maxIdle: maxIdle,
      maxLifetime: maxLifetime,
    ),
  );

  /// Returns a copy with only the named fields changed; every field left
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
  /// of its existence.
  ///
  /// The header map can change in two mutually-exclusive ways. [headers]
  /// *replaces* the map wholesale — the historical contract, kept because it is
  /// the only way a copy can *remove* a header — and, being a full new header
  /// state of unknown provenance, it passes the full public gate (normalize +
  /// control-char scan). [addHeaders] *merges over* the existing map: a supplied
  /// name overrides that name, every other existing header is carried through,
  /// and only the additions are re-normalized and re-scanned — the existing map
  /// already passed the gate at its own construction and is trusted as-is, so a
  /// rebuild that only adds a header (the middleware pattern: cors, etag, gzip)
  /// does not re-walk every header the handler already set. Passing both is an
  /// authoring defect and throws. The body/upgrade invariants (the
  /// 101/empty-body upgrade guard, valid body type) re-run on every copy —
  /// [status] and [body] can change here — so a rebuild that *would* violate
  /// them, e.g. handing an upgrade response a body, still throws rather than
  /// produce a malformed value.
  Response copyWith({
    int? status,
    Map<String, List<String>>? headers,
    Map<String, List<String>>? addHeaders,
    Object? body,
  }) {
    if (headers != null && addHeaders != null) {
      throw ArgumentError(
        'pass either headers (replace) or addHeaders (merge), not both',
      );
    }
    final Map<String, List<String>> nextHeaders;
    if (headers != null) {
      // Replace: a full new header state of unknown provenance — full gate.
      nextHeaders = _normalize(headers);
      _rejectControlChars(nextHeaders);
    } else if (addHeaders != null) {
      // Merge: only the additions pass the header gate; they then merge over
      // the trusted existing map (a supplied name wins).
      final additions = _normalize(addHeaders);
      _rejectControlChars(additions);
      nextHeaders = this.headers.isEmpty
          ? additions
          : {...this.headers, ...additions};
    } else {
      // Nothing new: the existing map already passed the public gate, so it is
      // reused as-is — never re-lowercased, re-copied, or re-scanned.
      nextHeaders = this.headers;
    }
    return Response._trusted(
      status ?? this.status,
      nextHeaders,
      body ?? this.body,
      upgrade,
    );
  }

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

  /// Enforces the body/upgrade invariants shared by every constructor. Run
  /// unconditionally (not via assert): in a release binary an invalid body would
  /// otherwise be written as a silent empty 200, and an upgrade response answers
  /// by switching protocols, so its status is fixed at 101 and it carries no
  /// body (the switched protocol carries the bytes) — a mismatch here is an
  /// authoring defect, caught at the semantic layer before any transport tries —
  /// and fails — to realize it.
  static void _checkBody(int status, Object body, Upgrade? upgrade) {
    if (body is! String && body is! List<int> && body is! Stream<List<int>>) {
      throw ArgumentError.value(
        body,
        'body',
        'must be String, List<int>, or Stream<List<int>>',
      );
    }
    if (upgrade != null) {
      if (status != 101) {
        throw ArgumentError.value(
          status,
          'status',
          'an upgrade response must have status 101 (switching protocols)',
        );
      }
      if (body is! String || body.isNotEmpty) {
        throw ArgumentError.value(
          body,
          'body',
          'an upgrade response carries no body',
        );
      }
    }
  }

  /// Rejects CR/LF and other control characters in the names/values of an
  /// already-normalized header map — the response-splitting gate. A field value
  /// may carry HTAB (RFC 9110 §5.5: field-value allows HTAB alongside VCHAR/SP);
  /// only CR/LF and the other controls are the injection primitive to reject.
  static void _rejectControlChars(Map<String, List<String>> headers) {
    for (final e in headers.entries) {
      if (_hasControlChar(e.key)) {
        throw ArgumentError.value(
          e.key,
          'headers',
          'header name must not contain control characters',
        );
      }
      for (final value in e.value) {
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
