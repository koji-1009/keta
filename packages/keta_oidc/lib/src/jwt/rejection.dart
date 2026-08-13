library;

/// Why a token was rejected, as a **value**. Every way a JWT can fail — from a
/// segment that is not base64url to a signature that does not verify to an
/// audience that does not match — is one of the [final] subtypes of this sealed
/// type, so the set of reasons is closed and a caller can `switch` over it
/// exhaustively.
///
/// ## Why a type per reason, not a `String`
///
/// The reason has to be machine-readable, not a log line. The `oidc()`
/// middleware maps these to RFC 6750 `WWW-Authenticate` responses — a malformed
/// or unverifiable token is `error="invalid_token"`, and the reason decides the
/// human-readable `error_description`. Encoding the reason as the
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
sealed class const JwtRejection(
  /// A human-readable explanation, for logs and `error_description`. Never parse
  /// it — branch on the subtype instead.
  final String message,
) implements Exception {
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
final class const JwtMalformed(super.message) extends JwtRejection;

/// The token's `alg` is a genuine, supported algorithm, but not one permitted
/// for this validation: it is absent from the caller's allowlist, or it
/// disagrees with the resolved key (the key declares a different `alg`, is the
/// wrong key type for the algorithm, or — for EC — is on the wrong curve).
/// Distinct from [JwtMalformed], which covers algorithms this server never
/// supports at all; this is a *policy* rejection of a supported algorithm.
final class const JwtAlgorithmNotAllowed(super.message) extends JwtRejection;

/// The signature did not verify against the resolved key. The token is
/// structurally sound and the algorithm is permitted, but the cryptographic
/// check failed — the token was forged, tampered with, or signed by a key this
/// server does not hold.
final class const JwtBadSignature(super.message) extends JwtRejection;

/// The token carries no `exp` (expiration) claim at all.
///
/// A token an OIDC resource server accepts **must** be expirable: RFC 9068 §4
/// makes `exp` REQUIRED for JWT access tokens, and keta_oidc's whole revocation
/// story is short token lifetimes (introspection is a judged absence, E-33) — a
/// token with no `exp` never expires and would validate forever on a signature
/// that never has to be reissued, defeating that model. So an absent `exp` is a
/// rejection, symmetric with the already-required `iss`/`aud`.
///
/// There is no "allow non-expiring tokens" knob. It is a distinct sealed reason
/// (not folded into [JwtExpired]) so a middleware's exhaustive `switch` is
/// forced to map "no expiry" rather than silently defaulting it.
final class const JwtExpirationRequired(super.message) extends JwtRejection;

/// The token is past its `exp` (expiration), accounting for the configured
/// leeway.
final class const JwtExpired(super.message) extends JwtRejection;

/// The token's `nbf` (not-before) is still in the future, accounting for the
/// configured leeway — it is not yet valid.
final class const JwtNotYetValid(super.message) extends JwtRejection;

/// The token's `iss` does not exactly equal the issuer this validation expects
/// (or the token carries no `iss`).
final class const JwtIssuerMismatch(super.message) extends JwtRejection;

/// The token's `aud` does not include the audience this validation expects (or
/// the token carries no `aud`).
final class const JwtAudienceMismatch(super.message) extends JwtRejection;

/// No key could be resolved for the token — the header names a `kid` the key
/// source does not hold, or names none and the source is ambiguous.
///
/// Key resolution (matching a `kid` against a JWKS) belongs to a [JwksSource],
/// not to the validator; the reason lives here so the failure model stays one
/// closed set rather than each resolver inventing its own.
final class const JwtUnknownKey(super.message) extends JwtRejection;
