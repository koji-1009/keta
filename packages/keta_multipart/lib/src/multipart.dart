library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HeaderValue, HttpException;
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:mime/mime.dart';

/// Byte and count ceilings for a multipart request. `App.maxBodyBytes` does NOT
/// apply here — reception rides the deliberate `c.bodyStream()` escape, so this
/// layer owns the limits. An oversized body or part raises [PayloadTooLarge]
/// (413); a part-count flood raises [BadRequest] (400, see [maxParts]).
class MultipartLimits {
  const MultipartLimits({
    this.maxTotalBytes = 8 * 1024 * 1024,
    this.maxPartBytes = 1024 * 1024,
    this.maxParts = 64,
  });

  /// Cap on the whole request body, enforced while streaming. Bytes in parts
  /// the consumer skips still count here — they are drained through the same
  /// meter (see [parts]) — so an attacker cannot hide payload in unread parts.
  final int maxTotalBytes;

  /// Cap on a single part, enforced on every read path — [Part.bytes],
  /// [Part.text], AND the unbuffered [Part.stream] — as [PayloadTooLarge].
  final int maxPartBytes;

  /// Cap on the number of parts, a flood-DoS guard. A part-count flood is a
  /// malformed/abusive request rather than an oversized payload, so exceeding
  /// this raises [BadRequest] (400), not [PayloadTooLarge] (413).
  final int maxParts;
}

/// One part of a multipart body. The [stream] is the deliberate unbuffered path
/// (persist a large upload without holding it in memory); [bytes]/[text] are the
/// buffered readers. Every path is bounded by `MultipartLimits.maxPartBytes` —
/// the API owns the size limit, the caller never has to.
///
/// A part's body may be read at most once, via exactly one of [stream],
/// [bytes], or [text]; a second read throws [StateError] (the backing MIME
/// stream is single-subscription). Reading is optional: a consumer may advance
/// the outer `Stream<Part>` without touching a part, and [parts] drains the
/// skipped body for it (charged to `maxTotalBytes`), so out-of-order or partial
/// consumption can neither deadlock nor smuggle uncounted bytes.
class Part {
  Part._(this._source, this._maxBytes);
  final MimeMultipart _source;
  final int _maxBytes;

  /// Whether the body has been claimed (read or drained). Guards the
  /// single-subscription MIME stream against a second listen and tells [parts]
  /// whether a skipped part still needs draining.
  bool _taken = false;

  /// The part's headers, lower-cased by the MIME parser.
  Map<String, String> get headers => _source.headers;

  /// The `name` of the form field, or null.
  String? get name => _disposition('name');

  /// The `filename` for a file part, or null for a plain field.
  String? get filename => _disposition('filename');

  /// The raw part body, unbuffered, but still bounded: the returned stream
  /// throws [PayloadTooLarge] the moment cumulative bytes exceed `maxPartBytes`.
  /// A caller that legitimately needs more must raise `maxPartBytes` — the limit
  /// is never silently bypassed on this path.
  Stream<List<int>> get stream {
    _claim();
    return _limitPart(_source);
  }

  /// The part body buffered into bytes, failing with [PayloadTooLarge] past
  /// `maxPartBytes`.
  Future<List<int>> bytes() async {
    final builder = BytesBuilder(copy: false);
    // Route through [stream] so the per-part limit lives in exactly one place.
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// The part body decoded as UTF-8 (subject to the same per-part limit).
  Future<String> text() async => utf8.decode(await bytes());

  /// Marks the body as consumed, rejecting a second read of the
  /// single-subscription MIME stream with a diagnostic instead of an opaque
  /// "already listened" [StateError] from deep in the stream machinery.
  void _claim() {
    if (_taken) {
      throw StateError('multipart part body already consumed');
    }
    _taken = true;
  }

  /// Drains an unread body when the consumer advances past it. Draining the raw
  /// `_source` (not [stream]) deliberately skips the per-part cap: a skipped
  /// part is not an error, but its bytes must still flow through the total meter
  /// upstream in [parts], so they cannot be used to smuggle payload past
  /// `maxTotalBytes`. A no-op once the body has been taken.
  Future<void> _drainIfUnread() async {
    if (_taken) return;
    _taken = true;
    await _source.drain<void>();
  }

  /// Wraps a body stream so cumulative bytes past `maxPartBytes` abort with
  /// [PayloadTooLarge] rather than being buffered or forwarded.
  Stream<List<int>> _limitPart(Stream<List<int>> source) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      if (total > _maxBytes) {
        throw PayloadTooLarge('multipart part exceeds $_maxBytes bytes');
      }
      yield chunk;
    }
  }

  String? _disposition(String key) {
    final value = _source.headers['content-disposition'];
    if (value == null) return null;
    try {
      // `HeaderValue.parse` implements the RFC 2183 / 6266 quoted-string rules
      // that a regex cannot: backslash-escaped quotes inside a quoted value
      // (`filename="a\"b"`), bare unquoted tokens (legal, emitted by non-browser
      // clients), and case-insensitive parameter names (all lower-cased). RFC
      // 5987 extended values (`filename*=`) stay unsupported by design — they
      // land under the distinct key `filename*`, so a percent-encoded name reads
      // as absent here rather than being mis-decoded.
      return HeaderValue.parse(value).parameters[key];
    } on HttpException {
      // A malformed header (e.g. an unterminated quote) yields no parameter
      // rather than tearing down the whole part stream from a synchronous getter.
      return null;
    }
  }
}

/// Parses [c]'s `multipart/form-data` body into a stream of [Part]s, delegating
/// boundary parsing to package:mime. A non-multipart request (or a missing
/// boundary) is a [BadRequest]; an oversized body or part is a [PayloadTooLarge];
/// a part-count flood is a [BadRequest].
///
/// Parts need not be read in order or at all: when the consumer advances, an
/// untouched part's body is drained for it — charged to `maxTotalBytes` — so a
/// skipped part can neither deadlock the underlying single-subscription MIME
/// stream nor hide uncounted bytes.
Stream<Part> parts<E>(
  Context<E> c, {
  MultipartLimits limits = const MultipartLimits(),
}) async* {
  final contentType = c.header('content-type') ?? '';
  if (!contentType.toLowerCase().startsWith('multipart/form-data')) {
    throw const BadRequest('expected a multipart/form-data body');
  }
  final boundary = _boundary(contentType);
  if (boundary == null) {
    throw const BadRequest('multipart request is missing its boundary');
  }

  final bounded = _limitTotal(c.bodyStream(), limits.maxTotalBytes);
  var count = 0;
  await for (final source in bounded.transform(
    MimeMultipartTransformer(boundary),
  )) {
    if (++count > limits.maxParts) {
      throw BadRequest('multipart exceeds ${limits.maxParts} parts');
    }
    final part = Part._(source, limits.maxPartBytes);
    yield part;
    // The consumer has finished with this part (its loop body ran to the point
    // of requesting the next element). Drain anything it left unread: the MIME
    // parser only surfaces the next part once the current body is consumed, and
    // draining routes those bytes through `_limitTotal` above so they count
    // toward the total. This makes the documented "consume in order" footgun
    // unrepresentable without a race — at this point nothing is reading `part`.
    await part._drainIfUnread();
  }
}

String? _boundary(String contentType) {
  try {
    // The same RFC-compliant parser as the disposition parameters: it keeps a
    // quoted boundary that itself contains ';' intact (`boundary="a;b"`, legal
    // per RFC 2046), which a naive `split(';')` would mangle, and honors a
    // case-insensitive `Boundary=` parameter name.
    final value = HeaderValue.parse(contentType).parameters['boundary'];
    return (value == null || value.isEmpty) ? null : value;
  } on HttpException {
    return null;
  }
}

Stream<List<int>> _limitTotal(Stream<List<int>> source, int maxBytes) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw PayloadTooLarge('multipart body exceeds $maxBytes bytes');
    }
    yield chunk;
  }
}
