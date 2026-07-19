library;

import '../jwt/jwk.dart';
import '../jwt/jws.dart';
import '../jwt/rejection.dart';
import 'jwk_set.dart';
import 'jwks_source.dart';

/// A [JwksSource] over a **fixed** set of keys — no I/O, no refresh. The seam
/// for tests, for air-gapped deployments that ship their issuer's keys as
/// configuration, and for any case where the key set is known ahead of time and
/// never rotates at runtime.
///
/// Because the key set never changes, the identity contract is trivially the
/// strongest it can be: the same [Jwk] instance is returned for a key on every
/// call, for the life of this object. [resolve] never throws [JwksUnavailable]
/// (there is nothing to be unavailable); a header with no matching key is a
/// [JwtUnknownKey].
final class StaticJwks implements JwksSource {
  /// Wraps an already-parsed [JwkSet].
  StaticJwks(this._set);

  /// Builds from a decoded-JSON JWKS document (`{"keys": [...]}`). Throws
  /// [JwksMalformed] if the document shape is wrong; unusable individual keys
  /// are skipped (see [JwkSet]).
  factory StaticJwks.fromJson(Map<String, Object?> json) =>
      StaticJwks(JwkSet.fromJson(json));

  /// Builds from a JWKS JSON string. Throws [JwksMalformed] on a malformed
  /// document.
  factory StaticJwks.parse(String text) => StaticJwks(JwkSet.parse(text));

  final JwkSet _set;

  /// The parsed key set, exposed so a caller can inspect which entries were
  /// [JwkSet.skipped].
  JwkSet get keys => _set;

  @override
  Future<Jwk> resolve(JoseHeader header) async {
    final jwk = _set.lookup(header);
    if (jwk == null) {
      throw JwtUnknownKey(_missMessage(header, _set));
    }
    return jwk;
  }
}

/// The [JwtUnknownKey] message for a header that resolved to no key.
String _missMessage(JoseHeader header, JwkSet set) {
  final kid = header.kid;
  if (kid != null) {
    return 'no key in the JWKS matches kid "$kid"';
  }
  return 'token has no "kid" and the JWKS does not hold exactly one usable key '
      '(${set.keys.length} present)';
}
