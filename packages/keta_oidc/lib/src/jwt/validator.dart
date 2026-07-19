library;

import 'algorithm.dart';
import 'claims.dart';
import 'jwk.dart';
import 'jws.dart';
import 'rejection.dart';
import 'signature_verifier.dart';

/// Validates an already-parsed [Jws] against a resolved [Jwk]: it applies the
/// algorithm allowlist and the key cross-check, verifies the signature through a
/// [SignatureVerifier], and judges the temporal/issuer/audience claims — then
/// returns the token's [JwtClaims].
///
/// ## What it does *not* do
///
/// It does not parse the compact token ([Jws.parse] does that) and it does not
/// resolve the key from the header's `kid` (the JWKS wave does that, and raises
/// [JwtUnknownKey] when it cannot). The pipeline is deliberately three separate
/// steps — parse, resolve, validate — so a caller reads the header's `kid` to
/// pick a key *before* this validator ever runs, which is the order
/// JWKS-based verification requires. This wave owns parse and validate; the
/// resolve step is a clean seam left for JWKS.
///
/// ## Order of checks
///
/// 1. **Algorithm policy** — the token's `alg` must be in [algorithms], and must
///    agree with the resolved key (declared `alg`, key type, and EC curve).
/// 2. **Signature** — verified before any claim is read, so no unverified claim
///    is ever trusted.
/// 3. **Claims** — well-typedness (via [JwtClaims]), then `exp`/`nbf` (with
///    [leeway]), then `iss`, then `aud`.
///
/// Each failure is the corresponding [JwtRejection] subtype; a success returns
/// the [JwtClaims].
final class JwtValidator {
  /// Creates a validator.
  ///
  /// [algorithms] is the allowlist: the token's `alg` must be one of these. It
  /// is an explicit [Set] the caller supplies rather than "all five" by default,
  /// because the tightest correct set is per-deployment — an issuer that signs
  /// with `RS256` should be validated against exactly `{RS256}`, so a token
  /// arriving with any other (still-supported) algorithm is refused.
  ///
  /// [issuer] and [audience] are matched exactly: the token's `iss` must equal
  /// [issuer], and its `aud` must contain [audience].
  ///
  /// [leeway] absorbs small clock skew between this server and the issuer when
  /// checking `exp`/`nbf` (default 60s). [now] is the clock, injectable for
  /// tests; it defaults to [DateTime.now] and is read once per [validate] call.
  JwtValidator({
    required this.verifier,
    required this.algorithms,
    required this.issuer,
    required this.audience,
    this.leeway = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (algorithms.isEmpty) {
      throw ArgumentError.value(
        algorithms,
        'algorithms',
        'the algorithm allowlist must not be empty (no token could ever '
            'validate)',
      );
    }
  }

  /// The cryptographic backend that checks signatures.
  final SignatureVerifier verifier;

  /// The permitted algorithms; a token's `alg` must be one of these.
  final Set<JwsAlgorithm> algorithms;

  /// The exact issuer (`iss`) a token must carry.
  final String issuer;

  /// The audience (`aud`) a token must include.
  final String audience;

  /// Clock skew tolerance applied to `exp` and `nbf`.
  final Duration leeway;

  final DateTime Function() _now;

  /// Validates [jws] against [key], returning its [JwtClaims] on success.
  ///
  /// Throws the matching [JwtRejection] subtype otherwise: [JwtAlgorithmNotAllowed]
  /// (algorithm not permitted, or disagreeing with the key), [JwtBadSignature]
  /// (signature did not verify), [JwtExpired] / [JwtNotYetValid] (temporal),
  /// [JwtIssuerMismatch], [JwtAudienceMismatch], or [JwtMalformed] (a
  /// wrong-typed registered claim surfaced while reading claims).
  JwtClaims validate(Jws jws, Jwk key) {
    final algorithm = jws.header.algorithm;

    // 1. Algorithm policy.
    if (!algorithms.contains(algorithm)) {
      throw JwtAlgorithmNotAllowed(
        'token algorithm ${algorithm.joseName} is not in the allowlist '
        '(${algorithms.map((a) => a.joseName).join(', ')})',
      );
    }
    _checkKeyAgreesWithAlgorithm(key, algorithm);

    // 2. Signature — before any claim is trusted.
    final ok = verifier.verify(
      key: key,
      algorithm: algorithm,
      signingInput: jws.signingInput,
      signature: jws.signature,
    );
    if (!ok) {
      throw const JwtBadSignature('signature does not verify against the key');
    }

    // 3. Claims. Typing first (a wrong-typed registered claim is JwtMalformed),
    // then temporal, issuer, audience.
    final claims = JwtClaims.fromJson(jws.payload);
    final now = _now();

    final exp = claims.expiration;
    if (exp != null && now.isAfter(exp.add(leeway))) {
      throw JwtExpired(
        'token expired at ${exp.toIso8601String()} '
        '(leeway ${leeway.inSeconds}s, now ${now.toUtc().toIso8601String()})',
      );
    }

    final nbf = claims.notBefore;
    if (nbf != null && now.isBefore(nbf.subtract(leeway))) {
      throw JwtNotYetValid(
        'token not valid before ${nbf.toIso8601String()} '
        '(leeway ${leeway.inSeconds}s, now ${now.toUtc().toIso8601String()})',
      );
    }

    if (claims.issuer != issuer) {
      throw JwtIssuerMismatch(
        'token issuer ${claims.issuer == null ? '(absent)' : '"${claims.issuer}"'} '
        'does not equal expected issuer "$issuer"',
      );
    }

    if (!claims.audience.contains(audience)) {
      throw JwtAudienceMismatch(
        'token audience ${claims.audience.isEmpty ? '(absent)' : claims.audience} '
        'does not include expected audience "$audience"',
      );
    }

    return claims;
  }

  /// Cross-checks the resolved [key] against the token's [algorithm]: a key that
  /// declares a different `alg`, is the wrong key type, or (for EC) is on the
  /// wrong curve must not verify this token. This is the kid↔alg binding that
  /// stops a valid-but-wrong key from being pressed into service — the EC
  /// analogue of HMAC key confusion.
  void _checkKeyAgreesWithAlgorithm(Jwk key, JwsAlgorithm algorithm) {
    if (key.algorithm != null && key.algorithm != algorithm) {
      throw JwtAlgorithmNotAllowed(
        'token algorithm ${algorithm.joseName} disagrees with the key\'s '
        'declared algorithm ${key.algorithm!.joseName}',
      );
    }
    if (key.keyType != algorithm.keyType) {
      throw JwtAlgorithmNotAllowed(
        'token algorithm ${algorithm.joseName} needs a '
        '${algorithm.keyType.joseName} key, but the key is '
        '${key.keyType.joseName}',
      );
    }
    if (algorithm.curve != null && key.curve != algorithm.curve) {
      throw JwtAlgorithmNotAllowed(
        'token algorithm ${algorithm.joseName} needs a ${algorithm.curve} key, '
        'but the key is on curve ${key.curve}',
      );
    }
  }
}
