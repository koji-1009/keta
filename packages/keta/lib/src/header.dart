/// Typed headers: a codec seam, named accessors over it, and the small set of
/// header types keta itself needs.
///
/// A header arrives as a list of strings and is parsed at the point of use.
/// Done ad hoc, that parsing spreads: `gzip()` grew its own `accept-encoding`
/// reader, `etag()` its own `if-none-match` reader, and each was correct only
/// where someone remembered the RFC. A codec makes the parse one value, named
/// once, testable on its own, and reusable by the next reader.
///
/// **A malformed header is the client's, so it is a [BadRequest] (400).** This
/// is the opposite posture from a database row (a server-side defect, a 500):
/// a header came off the wire, so a value that does not parse is the caller's
/// to fix, and the response says so. A header whose *name* nobody sent is not
/// malformed — it is absent, and absence is answered by which accessor you
/// call, exactly as it is for query parameters.
library;

import 'cookie.dart';
import 'response.dart';

/// Converts a header's raw values to [T] and back.
///
/// [decode] receives every value of the header, in order, and never an empty
/// list — absence is handled before a codec is reached. It throws
/// [BadRequest] on a value it cannot parse.
///
/// [encode] is the inverse, for writing the header onto a response. A codec
/// that only ever reads still has to provide it; a type that cannot be written
/// is a sign the value is a parse result rather than a header.
final class HeaderCodec<T extends Object> {
  const HeaderCodec({required this.decode, required this.encode});
  final T Function(List<String> values) decode;
  final List<String> Function(T value) encode;
}

/// A header name bound to the codec that gives its values a type.
///
/// Const, so an accessor is a value an application can declare beside its
/// routes: `const requestId = HeaderAccessor('x-request-id', …)`. keta's own
/// are below.
final class HeaderAccessor<T extends Object> {
  const HeaderAccessor(this.name, this.codec);

  /// The header's name, lower-cased — the form request headers are keyed by.
  final String name;

  final HeaderCodec<T> codec;

  /// Renders [value] as the single-entry header map a response takes, so a
  /// typed value reaches the wire without the call site re-spelling the name:
  /// `c.json(body, headers: cacheControl.write(CacheControl.noStore))`.
  Map<String, List<String>> write(T value) => {name: codec.encode(value)};

  /// Decodes [values], or null when the header was absent. Shared by the
  /// Context accessors; exposed for a caller holding raw headers of its own.
  T? decodeAll(List<String> values) =>
      values.isEmpty ? null : codec.decode(values);
}

// --- Authorization ---------------------------------------------------------

/// An `Authorization` (or `Proxy-Authorization`) credential: a scheme and
/// whatever follows it, unparsed.
///
/// The scheme is compared case-insensitively per RFC 9110 and normalized to
/// lower case here; [credentials] is kept verbatim, because its shape depends
/// entirely on the scheme (base64 for Basic, a token for Bearer) and this type
/// has no business guessing which.
final class Authorization {
  const Authorization(this.scheme, this.credentials);
  final String scheme;
  final String credentials;

  /// True when this is the named scheme, compared case-insensitively.
  bool isScheme(String name) => scheme == name.toLowerCase();

  @override
  String toString() => 'Authorization($scheme)';
}

/// `Authorization`. A value with no scheme at all is a [BadRequest]; the
/// scheme's own credential format is not checked here.
const authorization = HeaderAccessor<Authorization>(
  'authorization',
  HeaderCodec(decode: _decodeAuthorization, encode: _encodeAuthorization),
);

Authorization _decodeAuthorization(List<String> values) {
  final raw = values.first.trim();
  final space = raw.indexOf(' ');
  if (space <= 0) {
    throw const BadRequest('malformed Authorization header');
  }
  return Authorization(
    raw.substring(0, space).toLowerCase(),
    raw.substring(space + 1).trim(),
  );
}

List<String> _encodeAuthorization(Authorization value) => [
  '${value.scheme} ${value.credentials}',
];

// --- Cache-Control ---------------------------------------------------------

/// The `Cache-Control` directives keta reads and writes.
///
/// Only the directives with a defined meaning for a response keta produces are
/// modelled. An unrecognized directive on the way in is dropped rather than
/// rejected: a proxy may add its own, and refusing the request over a directive
/// this server does not act on would fail a well-formed message.
final class CacheControl {
  const CacheControl({
    this.noStore = false,
    this.noCache = false,
    this.mustRevalidate = false,
    this.isPublic = false,
    this.isPrivate = false,
    this.immutable = false,
    this.maxAge,
    this.sMaxAge,
  });

  final bool noStore;
  final bool noCache;
  final bool mustRevalidate;
  final bool isPublic;
  final bool isPrivate;
  final bool immutable;
  final Duration? maxAge;
  final Duration? sMaxAge;

  @override
  String toString() => 'CacheControl(${_encodeCacheControl(this).first})';
}

/// `Cache-Control`.
const cacheControl = HeaderAccessor<CacheControl>(
  'cache-control',
  HeaderCodec(decode: _decodeCacheControl, encode: _encodeCacheControl),
);

CacheControl _decodeCacheControl(List<String> values) {
  var noStore = false;
  var noCache = false;
  var mustRevalidate = false;
  var isPublic = false;
  var isPrivate = false;
  var immutable = false;
  Duration? maxAge;
  Duration? sMaxAge;
  for (final directive in values.expand((v) => v.split(','))) {
    final token = directive.trim().toLowerCase();
    if (token.isEmpty) continue;
    final eq = token.indexOf('=');
    final name = eq == -1 ? token : token.substring(0, eq);
    final argument = eq == -1 ? null : token.substring(eq + 1).trim();
    switch (name) {
      case 'no-store':
        noStore = true;
      case 'no-cache':
        noCache = true;
      case 'must-revalidate':
        mustRevalidate = true;
      case 'public':
        isPublic = true;
      case 'private':
        isPrivate = true;
      case 'immutable':
        immutable = true;
      case 'max-age':
        maxAge = _deltaSeconds(argument, 'max-age');
      case 's-maxage':
        sMaxAge = _deltaSeconds(argument, 's-maxage');
    }
  }
  return CacheControl(
    noStore: noStore,
    noCache: noCache,
    mustRevalidate: mustRevalidate,
    isPublic: isPublic,
    isPrivate: isPrivate,
    immutable: immutable,
    maxAge: maxAge,
    sMaxAge: sMaxAge,
  );
}

Duration _deltaSeconds(String? argument, String directive) {
  final seconds = int.tryParse(argument?.replaceAll('"', '') ?? '');
  if (seconds == null || seconds < 0) {
    throw BadRequest('malformed Cache-Control $directive');
  }
  return Duration(seconds: seconds);
}

List<String> _encodeCacheControl(CacheControl value) {
  final parts = <String>[
    if (value.isPublic) 'public',
    if (value.isPrivate) 'private',
    if (value.noStore) 'no-store',
    if (value.noCache) 'no-cache',
    if (value.mustRevalidate) 'must-revalidate',
    if (value.immutable) 'immutable',
    if (value.maxAge != null) 'max-age=${value.maxAge!.inSeconds}',
    if (value.sMaxAge != null) 's-maxage=${value.sMaxAge!.inSeconds}',
  ];
  return [parts.join(', ')];
}

// --- Accept-Encoding -------------------------------------------------------

/// The content codings a client will accept, with their q-values.
///
/// This is the parse `gzip()` used to carry inline. `q=0` means *refused*, not
/// merely unpreferred, which is the part an ad hoc `contains('gzip')` check
/// gets wrong.
final class AcceptEncoding {
  const AcceptEncoding(this.qualities);

  /// Coding (lower-case, `*` included) to its q-value.
  final Map<String, double> qualities;

  /// The q-value [coding] was *explicitly* named with, or null when it was not
  /// named at all. Distinct from [wildcard] on purpose: RFC 9110 §12.5.3 gives
  /// a named coding precedence over `*`, so `gzip;q=0, *` refuses gzip, and a
  /// reader that could not tell "named 0" from "not named" would accept it.
  double? qualityOf(String coding) => qualities[coding.toLowerCase()];

  /// `*`'s q-value, or null when no wildcard was sent.
  double? get wildcard => qualities['*'];

  /// Whether [coding] may be used: its own q-value if named, else `*`'s, and in
  /// either case only when that value is above zero. [acceptsAny] is the form
  /// for a coding with aliases.
  bool accepts(String coding) => acceptsAny([coding]);

  /// [accepts] over a set of names for the same coding (`gzip` and its `x-gzip`
  /// alias). The first alias the client actually named decides; `*` applies
  /// only when none of them was named.
  bool acceptsAny(List<String> codings) {
    for (final coding in codings) {
      final named = qualityOf(coding);
      if (named != null) return named > 0;
    }
    final star = wildcard;
    return star != null && star > 0;
  }

  @override
  String toString() => 'AcceptEncoding($qualities)';
}

/// `Accept-Encoding`.
const acceptEncoding = HeaderAccessor<AcceptEncoding>(
  'accept-encoding',
  HeaderCodec(decode: _decodeAcceptEncoding, encode: _encodeAcceptEncoding),
);

AcceptEncoding _decodeAcceptEncoding(List<String> values) {
  final qualities = <String, double>{};
  for (final entry in values.expand((v) => v.split(','))) {
    final parts = entry.split(';');
    final coding = parts.first.trim().toLowerCase();
    if (coding.isEmpty) continue;
    var q = 1.0;
    for (final parameter in parts.skip(1)) {
      final token = parameter.trim().toLowerCase();
      if (!token.startsWith('q=')) continue;
      // A malformed q is treated as the default rather than a 400: the message
      // is still well-formed and the client's preference, not its request, is
      // what is unreadable.
      q = double.tryParse(token.substring(2)) ?? 1.0;
    }
    qualities[coding] = q;
  }
  return AcceptEncoding(qualities);
}

List<String> _encodeAcceptEncoding(AcceptEncoding value) => [
  value.qualities.entries
      .map((e) => e.value == 1.0 ? e.key : '${e.key};q=${e.value}')
      .join(', '),
];

// --- If-None-Match / ETag --------------------------------------------------

/// One entity tag: its opaque value and whether it is weak (`W/`).
final class EntityTag {
  const EntityTag(this.value, {this.weak = false});
  final String value;
  final bool weak;

  @override
  String toString() => weak ? 'W/"$value"' : '"$value"';
}

/// An `If-None-Match` condition: `*`, or a list of entity tags.
final class EntityTagCondition {
  const EntityTagCondition(this.tags, {this.any = false});

  /// `*` — matches whatever representation exists.
  static const EntityTagCondition star = EntityTagCondition([], any: true);

  final List<EntityTag> tags;
  final bool any;

  /// Weak comparison (RFC 9110 §8.8.3.2), which is what `If-None-Match`
  /// prescribes: the opaque values are compared and the weakness flags ignored.
  bool matches(String tag) =>
      any || tags.any((candidate) => candidate.value == tag);

  @override
  String toString() => any ? '*' : tags.join(', ');
}

/// `If-None-Match`.
const ifNoneMatch = HeaderAccessor<EntityTagCondition>(
  'if-none-match',
  HeaderCodec(decode: _decodeEntityTags, encode: _encodeEntityTags),
);

EntityTagCondition _decodeEntityTags(List<String> values) {
  final tags = <EntityTag>[];
  for (final entry in values.expand((v) => v.split(','))) {
    var token = entry.trim();
    if (token.isEmpty) continue;
    if (token == '*') return EntityTagCondition.star;
    var weak = false;
    if (token.startsWith('W/')) {
      weak = true;
      token = token.substring(2);
    }
    if (token.length >= 2 && token.startsWith('"') && token.endsWith('"')) {
      token = token.substring(1, token.length - 1);
    }
    tags.add(EntityTag(token, weak: weak));
  }
  return EntityTagCondition(tags);
}

List<String> _encodeEntityTags(EntityTagCondition value) => [
  value.any ? '*' : value.tags.join(', '),
];

// --- Range -----------------------------------------------------------------

/// A single byte range request: `bytes=<first>-<last>`, `bytes=<first>-`, or
/// `bytes=-<suffix>`.
///
/// Only one range is modelled. A multi-range request needs a
/// `multipart/byteranges` response, which is a body format rather than a header
/// concern; a server that does not produce one answers the whole
/// representation, which is always allowed.
final class ByteRange {
  const ByteRange({this.first, this.last, this.suffixLength})
    : assert(
        (suffixLength == null) != (first == null),
        'a byte range is either first[-last] or -suffix, never both or neither',
      );

  /// `bytes=<first>-<last>` — [last] null means "to the end".
  final int? first;
  final int? last;

  /// `bytes=-<suffixLength>` — the final [suffixLength] bytes.
  final int? suffixLength;

  /// Resolves against a representation of [totalLength], or null when the
  /// range is unsatisfiable (a 416).
  (int start, int endInclusive)? resolve(int totalLength) {
    if (totalLength <= 0) return null;
    if (suffixLength != null) {
      if (suffixLength == 0) return null;
      final start = suffixLength! >= totalLength
          ? 0
          : totalLength - suffixLength!;
      return (start, totalLength - 1);
    }
    final start = first!;
    if (start >= totalLength) return null;
    final end = last == null || last! >= totalLength ? totalLength - 1 : last!;
    if (end < start) return null;
    return (start, end);
  }

  @override
  String toString() => suffixLength != null
      ? 'bytes=-$suffixLength'
      : 'bytes=$first-${last ?? ''}';
}

/// `Range`, restricted to a single `bytes` range.
///
/// A syntactically invalid range is not a [BadRequest]: RFC 9110 says a server
/// that cannot make sense of a Range MUST ignore it and answer the whole
/// representation. Ignoring is expressed by decoding to null rather than by
/// throwing, so the caller sees "no usable range" and serves 200.
const range = HeaderAccessor<ByteRange>(
  'range',
  HeaderCodec(decode: _decodeRange, encode: _encodeRange),
);

ByteRange _decodeRange(List<String> values) {
  final raw = values.first.trim().toLowerCase();
  const prefix = 'bytes=';
  if (!raw.startsWith(prefix)) throw const _UnusableRange();
  final spec = raw.substring(prefix.length).trim();
  // Only the first range of a multi-range request is honoured; see [ByteRange].
  final first = spec.split(',').first.trim();
  final dash = first.indexOf('-');
  if (dash == -1) throw const _UnusableRange();
  final start = first.substring(0, dash).trim();
  final end = first.substring(dash + 1).trim();
  if (start.isEmpty) {
    final suffix = int.tryParse(end);
    if (suffix == null) throw const _UnusableRange();
    return ByteRange(suffixLength: suffix);
  }
  final from = int.tryParse(start);
  if (from == null) throw const _UnusableRange();
  if (end.isEmpty) return ByteRange(first: from);
  final to = int.tryParse(end);
  if (to == null) throw const _UnusableRange();
  return ByteRange(first: from, last: to);
}

List<String> _encodeRange(ByteRange value) => [value.toString()];

/// Thrown by the `Range` codec and swallowed by the Context accessors, so an
/// unreadable Range reads as absent (RFC 9110: ignore it) instead of 400.
class _UnusableRange implements Exception {
  const _UnusableRange();
}

/// Whether [error] is the sentinel meaning "this header is to be ignored".
bool isIgnorableHeader(Object error) => error is _UnusableRange;

// --- Set-Cookie ------------------------------------------------------------

/// `Set-Cookie`, the multi-value response header. [SetCookie] already validates
/// at construction, so this brings it under the same accessor as everything
/// else rather than replacing it: `headers: setCookies.write([SetCookie(…)])`.
const setCookies = HeaderAccessor<List<SetCookie>>(
  'set-cookie',
  HeaderCodec(decode: _decodeSetCookies, encode: _encodeSetCookies),
);

List<SetCookie> _decodeSetCookies(List<String> values) => throw StateError(
  'Set-Cookie is a response header; keta does not parse it from a request',
);

List<String> _encodeSetCookies(List<SetCookie> value) => [
  for (final cookie in value) cookie.toHeaderValue(),
];
