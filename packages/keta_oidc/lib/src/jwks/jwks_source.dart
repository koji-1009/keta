library;

import '../jwt/jwk.dart';
import '../jwt/jws.dart';
import '../jwt/rejection.dart';

/// The seam that resolves a token's [JoseHeader] to the [Jwk] to verify it with.
/// It is where key *sourcing* lives — static keys, or an HTTP JWKS endpoint with
/// caching and refresh — kept behind one interface so the validator and the
/// middleware (a later wave) depend on the seam, not on where keys come from.
///
/// ## Contract
///
/// [resolve] returns the [Jwk] that verifies a token with [header]:
///
/// * **Exact `kid` match.** A header with a `kid` resolves to the key whose
///   `kid` equals it exactly; nothing else.
/// * **No `kid`.** If the source holds exactly one usable signature key, that
///   key is used; otherwise (zero, or more than one — ambiguous) it is a
///   [JwtUnknownKey]. This is the posture [JwtUnknownKey] documents.
/// * **No matching key ⇒ [JwtUnknownKey].** When the source cannot produce a key
///   for the header, it throws [JwtUnknownKey] — the existing sealed rejection
///   reason, reused so the failure model stays closed.
/// * **Stable identity.** For as long as a key remains in the source's current
///   view, [resolve] returns the **same [Jwk] instance** (identity, not just
///   equality) on every call. A [SignatureVerifier] may therefore cache a
///   derived native key against that instance (see [Jwk]). A source that
///   refreshes preserves identity for keys whose material is unchanged across
///   the refresh, and hands out a fresh instance only for a key that is new or
///   whose material changed.
///
/// ## Two failure kinds, kept apart
///
/// A resolve can fail two very different ways, and the difference is the type:
///
/// * [JwtUnknownKey] (a [JwtRejection]) — the source is healthy and simply holds
///   no key for this token. The token is unauthorized; the middleware maps this
///   to `401`.
/// * [JwksUnavailable] (**not** a [JwtRejection]) — the source could not be
///   consulted at all and has nothing cached to fall back on. The token is not
///   bad; the key infrastructure is down. The middleware maps this to a `503`.
///   Keeping it outside the [JwtRejection] hierarchy stops "the IdP is down"
///   from ever being reported as "your token is invalid".
abstract interface class JwksSource {
  /// Resolves [header] to its verification [Jwk].
  ///
  /// Throws [JwtUnknownKey] when no key matches (or a `kid`-less header is
  /// ambiguous), and [JwksUnavailable] when the source is unreachable with
  /// nothing cached to serve.
  Future<Jwk> resolve(JoseHeader header);
}

/// The key source could not be consulted and had no cached keys to fall back on
/// — the JWKS endpoint (or OIDC discovery) was unreachable, timed out, or
/// returned something unusable, and this is a cold source.
///
/// **Not a [JwtRejection].** The presented token is not the problem; the key
/// infrastructure is. The middleware wave maps this to a `503` (with the token
/// left unjudged), never to a `401`. The originating error is preserved in
/// [cause] (e.g. a `SocketException`, `TimeoutException`, or [JwksMalformed]),
/// so a raw transport error never escapes this package unwrapped.
final class JwksUnavailable implements Exception {
  const JwksUnavailable(this.message, {this.cause});

  /// A human-readable explanation.
  final String message;

  /// The underlying error that caused the source to be unavailable, if any.
  final Object? cause;

  @override
  String toString() =>
      'JwksUnavailable: $message${cause == null ? '' : ' (cause: $cause)'}';
}
