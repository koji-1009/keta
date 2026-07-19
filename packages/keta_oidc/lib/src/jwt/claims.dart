library;

import 'rejection.dart';

/// The registered claims of a JWT payload (RFC 7519 §4.1), typed, plus the
/// [raw] payload for everything else.
///
/// Only the registered claims that a resource server acts on are lifted to typed
/// fields. Application claims — `scope`, roles, tenant, anything custom — stay in
/// [raw] for a later authorization layer to read; this layer does not presume
/// their shapes.
///
/// This is a *parsed* view, not a *validated* one: constructing a [JwtClaims]
/// checks that each registered claim has the right JSON type, but says nothing
/// about whether the token is expired, from the right issuer, or for the right
/// audience. That temporal/issuer/audience judgement is the validator's, which
/// needs a clock and the caller's expectations to make it.
final class JwtClaims {
  const JwtClaims._({
    required this.issuer,
    required this.subject,
    required this.audience,
    required this.expiration,
    required this.notBefore,
    required this.issuedAt,
    required this.raw,
  });

  /// Extracts the registered claims from a decoded-JSON payload [map].
  ///
  /// Throws [JwtMalformed] when a registered claim is present with the wrong
  /// JSON type: `iss`/`sub` that are not strings, `aud` that is neither a string
  /// nor an array of strings, or `exp`/`nbf`/`iat` that are not numbers. A
  /// wrong-typed registered claim is a structurally broken token, not merely an
  /// invalid one — surfacing it here means the validator only ever sees
  /// well-typed claims.
  factory JwtClaims.fromJson(Map<String, Object?> map) {
    return JwtClaims._(
      issuer: _string(map, 'iss'),
      subject: _string(map, 'sub'),
      audience: _audience(map),
      expiration: _numericDate(map, 'exp'),
      notBefore: _numericDate(map, 'nbf'),
      issuedAt: _numericDate(map, 'iat'),
      raw: map,
    );
  }

  /// The issuer (`iss`), or `null` if absent.
  final String? issuer;

  /// The subject (`sub`), or `null` if absent. Surfaced but never *required* by
  /// this layer — a token without a `sub` is not rejected here.
  final String? subject;

  /// The audience (`aud`) as a list, always. RFC 7519 allows `aud` to be either
  /// a single string or an array of strings; both are normalised to a list here,
  /// empty when `aud` is absent, so callers never branch on the wire shape.
  final List<String> audience;

  /// The expiration time (`exp`) as UTC, or `null` if absent. Whether the token
  /// is past it is the validator's judgement, not a property of this value.
  final DateTime? expiration;

  /// The not-before time (`nbf`) as UTC, or `null` if absent.
  final DateTime? notBefore;

  /// The issued-at time (`iat`) as UTC, or `null` if absent.
  ///
  /// **Surfaced but not validated for age.** RFC 7519 makes `iat` informational
  /// — it is not a validity boundary the way `exp`/`nbf` are — so this layer
  /// does not reject a token for being "too old" by default. A maximum-age knob
  /// is a deliberate non-feature here rather than a forgotten one; it can be
  /// added when a concrete need appears, without changing this shape.
  final DateTime? issuedAt;

  /// The full decoded payload, including registered claims. Read application
  /// claims (`scope`, roles, …) from here.
  final Map<String, Object?> raw;

  static String? _string(Map<String, Object?> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is! String) {
      throw JwtMalformed('claim "$key" must be a string');
    }
    return v;
  }

  static List<String> _audience(Map<String, Object?> map) {
    final v = map['aud'];
    if (v == null) return const [];
    if (v is String) return List<String>.unmodifiable([v]);
    if (v is List && v.every((e) => e is String)) {
      return List<String>.unmodifiable(v.cast<String>());
    }
    throw const JwtMalformed(
      'claim "aud" must be a string or an array of strings',
    );
  }

  /// The largest `|microsecondsSinceEpoch|` [DateTime.fromMicrosecondsSinceEpoch]
  /// accepts is `8.64e18` (roughly year ±275760); a hair inside it is used as the
  /// bound so that double rounding at the boundary can never push `.round()` one
  /// past the limit. A `NumericDate` beyond ~year 275759 is therefore rejected as
  /// [JwtMalformed] rather than accepted — a **judged posture**: a token claiming
  /// to expire a quarter-million years out is a hostile or broken value, not a
  /// timestamp to honour, and rejecting it keeps the failure a `401` (malformed
  /// token) instead of a `500` (an [ArgumentError] escaping the validator).
  static const int _maxNumericDateMicros = 8639999999999000000;

  static DateTime? _numericDate(Map<String, Object?> map, String key) {
    final v = map[key];
    if (v == null) return null;
    // A NumericDate is seconds since the epoch and MAY be non-integer
    // (RFC 7519 §2). Reject a non-number outright; accept int or double.
    if (v is! num) {
      throw JwtMalformed('claim "$key" must be a number (NumericDate)');
    }
    // A hostile but valid-JSON number must not escape as anything other than a
    // JwtMalformed. Two traps to disarm *before* arithmetic, because
    // avoid_catching_errors forbids catching what they would throw:
    //   * a non-finite value (e.g. `1e400` decodes to Infinity) — `.round()`
    //     throws UnsupportedError on it;
    //   * a value whose microseconds fall outside DateTime's representable range
    //     (e.g. `9.9e18` seconds) — `fromMicrosecondsSinceEpoch` throws
    //     ArgumentError/RangeError on it.
    final seconds = v.toDouble();
    if (!seconds.isFinite) {
      throw JwtMalformed(
        'claim "$key" is not a representable NumericDate (non-finite)',
      );
    }
    final micros = seconds * Duration.microsecondsPerSecond;
    if (micros.abs() > _maxNumericDateMicros) {
      throw JwtMalformed(
        'claim "$key" is not a representable NumericDate (out of range)',
      );
    }
    return DateTime.fromMicrosecondsSinceEpoch(micros.round(), isUtc: true);
  }
}
