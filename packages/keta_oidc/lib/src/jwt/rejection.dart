library;

/// Why a token was rejected, as a **value**. Every way a JWT can fail — from a
/// segment that is not base64url to a signature that does not verify to an
/// audience that does not match — is one of the [final] subtypes of this sealed
/// type, so the set of reasons is closed and a caller can `switch` over it
/// exhaustively.
///
/// ## Why a type per reason, not a `String`
///
/// The reason has to be machine-readable, not a log line. The oidc() middleware
/// (a later wave) maps these to RFC 6750 `WWW-Authenticate` responses — a
/// malformed or unverifiable token is `error="invalid_token"`, and the reason
/// decides the human-readable `error_description`. Encoding the reason as the
/// *type* (the same posture keta core takes with `TransientFailure`: "the
/// retryability is the type") means the mapping is an exhaustive `switch` the
/// compiler checks, and a new reason cannot be added without every mapper being
/// forced to handle it.
///
/// ## Why not `KetaException`
///
/// keta core's `KetaException` carries an HTTP `status`. That is exactly the
/// coupling the JWT layer must not have: decoding and validating a token is not
/// an HTTP operation, and this package must be usable without importing HTTP
/// semantics. [JwtRejection] is a parallel sealed hierarchy that names *why the
/// token is bad* and stops there; turning a reason into a 401 is the
/// middleware's job, not the JWT layer's.
///
/// A [JwtRejection] `implements Exception` (not `Error`): a rejected token is an
/// input-validation outcome — a caller is expected to catch it and answer 401 —
/// not a programming defect. Author defects in this package (a JWK that cannot
/// be parsed into a key the backend understands, a misuse of the API) surface as
/// [StateError] / [ArgumentError], following keta's split of "input violation →
/// typed rejection, author defect → thrown error".
sealed class JwtRejection implements Exception {
  const JwtRejection(this.message);

  /// A human-readable explanation, for logs and `error_description`. Never parse
  /// it — branch on the subtype instead.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The token is not a well-formed JWS at all: it does not have exactly three
/// base64url segments, a segment is not strict RFC 7515 base64url (padded, or
/// using a non-URL-alphabet character), the header or payload is not a JSON
/// object, the header has no `alg`, a registered claim has the wrong JSON type,
/// or — the security-critical case — the header's `alg` is one this server
/// never accepts (`none`, any `HS*`, any `PS*`, or an unrecognised value). Such
/// an `alg` never resolves to a [JwsAlgorithm], so a token carrying it is
/// rejected here, before any key is consulted.
final class JwtMalformed extends JwtRejection {
  const JwtMalformed(super.message);
}

/// The token's `alg` is a genuine, supported algorithm, but not one permitted
/// for this validation: it is absent from the caller's allowlist, or it
/// disagrees with the resolved key (the key declares a different `alg`, is the
/// wrong key type for the algorithm, or — for EC — is on the wrong curve).
/// Distinct from [JwtMalformed], which covers algorithms this server never
/// supports at all; this is a *policy* rejection of a supported algorithm.
final class JwtAlgorithmNotAllowed extends JwtRejection {
  const JwtAlgorithmNotAllowed(super.message);
}

/// The signature did not verify against the resolved key. The token is
/// structurally sound and the algorithm is permitted, but the cryptographic
/// check failed — the token was forged, tampered with, or signed by a key this
/// server does not hold.
final class JwtBadSignature extends JwtRejection {
  const JwtBadSignature(super.message);
}

/// The token is past its `exp` (expiration), accounting for the configured
/// leeway.
final class JwtExpired extends JwtRejection {
  const JwtExpired(super.message);
}

/// The token's `nbf` (not-before) is still in the future, accounting for the
/// configured leeway — it is not yet valid.
final class JwtNotYetValid extends JwtRejection {
  const JwtNotYetValid(super.message);
}

/// The token's `iss` does not exactly equal the issuer this validation expects
/// (or the token carries no `iss`).
final class JwtIssuerMismatch extends JwtRejection {
  const JwtIssuerMismatch(super.message);
}

/// The token's `aud` does not include the audience this validation expects (or
/// the token carries no `aud`).
final class JwtAudienceMismatch extends JwtRejection {
  const JwtAudienceMismatch(super.message);
}

/// No key could be resolved for the token — the header names a `kid` the key
/// source does not hold, or names none and the source is ambiguous.
///
/// Key resolution (matching a `kid` against a JWKS) is the JWKS wave's job, not
/// this one's; [JwtUnknownKey] is defined here so the failure model is complete
/// and enumerable now, and so the JWKS wave raises a reason that already lives
/// in this sealed set rather than inventing its own.
final class JwtUnknownKey extends JwtRejection {
  const JwtUnknownKey(super.message);
}
