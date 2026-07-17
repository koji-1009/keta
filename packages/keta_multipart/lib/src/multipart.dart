library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:mime/mime.dart';

/// Byte ceilings for a multipart request. `App.maxBodyBytes` does NOT apply here
/// — reception rides the deliberate `c.bodyStream()` escape, so this layer owns
/// the limits. Exceeding any of them raises a [PayloadTooLarge].
class MultipartLimits {
  const MultipartLimits({
    this.maxTotalBytes = 8 * 1024 * 1024,
    this.maxPartBytes = 1024 * 1024,
    this.maxParts = 64,
  });

  /// Cap on the whole request body, enforced while streaming.
  final int maxTotalBytes;

  /// Cap on a single part, enforced by the buffered readers [Part.bytes] /
  /// [Part.text].
  final int maxPartBytes;

  /// Cap on the number of parts, a flood-DoS guard.
  final int maxParts;
}

/// One part of a multipart body. The [stream] is the deliberate unbuffered path
/// (persist a large upload without holding it in memory); [bytes]/[text] are the
/// buffered readers, bounded by `MultipartLimits.maxPartBytes`.
///
/// Parts must be consumed in order — reading a part (via [stream], [bytes], or
/// [text]) before advancing the outer `Stream<Part>` — as the underlying MIME
/// stream is single-subscription.
class Part {
  Part._(this._source, this._maxBytes);
  final MimeMultipart _source;
  final int _maxBytes;

  /// The part's headers, lower-cased by the MIME parser.
  Map<String, String> get headers => _source.headers;

  /// The `name` of the form field, or null.
  String? get name => _disposition('name');

  /// The `filename` for a file part, or null for a plain field.
  String? get filename => _disposition('filename');

  /// The raw part body, unbuffered. The caller owns the size limit here.
  Stream<List<int>> get stream => _source;

  /// The part body buffered into bytes, failing with [PayloadTooLarge] past
  /// `maxPartBytes`.
  Future<List<int>> bytes() async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in _source) {
      total += chunk.length;
      if (total > _maxBytes) {
        throw PayloadTooLarge('multipart part exceeds $_maxBytes bytes');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// The part body decoded as UTF-8 (subject to the same per-part limit).
  Future<String> text() async => utf8.decode(await bytes());

  String? _disposition(String key) {
    final value = _source.headers['content-disposition'];
    if (value == null) return null;
    // The lookbehind keeps `name=` from matching inside `filename=`.
    return RegExp('(?<![a-zA-Z])$key="([^"]*)"').firstMatch(value)?.group(1);
  }
}

/// Parses [c]'s `multipart/form-data` body into a stream of [Part]s, delegating
/// boundary parsing to package:mime. A non-multipart request (or a missing
/// boundary) is a [BadRequest]; exceeding [limits] is a [PayloadTooLarge].
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
  await for (final part in bounded.transform(
    MimeMultipartTransformer(boundary),
  )) {
    if (++count > limits.maxParts) {
      throw PayloadTooLarge('multipart exceeds ${limits.maxParts} parts');
    }
    yield Part._(part, limits.maxPartBytes);
  }
}

String? _boundary(String contentType) {
  for (final param in contentType.split(';').skip(1)) {
    final trimmed = param.trim();
    // HTTP parameter names are case-insensitive (RFC 9110 §5.6.6); only the
    // `boundary=` prefix is matched case-insensitively, the value itself is
    // taken verbatim.
    if (trimmed.toLowerCase().startsWith('boundary=')) {
      var value = trimmed.substring('boundary='.length);
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      return value.isEmpty ? null : value;
    }
  }
  return null;
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
