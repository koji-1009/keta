library;

/// The key type of a JWK (`kty`), restricted to the two families keta_oidc
/// verifies with: RSA and elliptic-curve. Symmetric keys (`oct`) have no place
/// here — HMAC verification is rejected by design (see [JwsAlgorithm]), so the
/// key type that would carry a shared secret is simply not modelled.
enum JwkKeyType {
  /// An RSA public key: components `n` (modulus) and `e` (exponent).
  rsa('RSA'),

  /// An elliptic-curve public key: components `crv`, `x`, `y`.
  ec('EC');

  const JwkKeyType(this.joseName);

  /// The `kty` value as it appears in JWK JSON (`"RSA"` / `"EC"`).
  final String joseName;

  /// The [JwkKeyType] for a JWK `kty` string, or `null` if it is neither of the
  /// two verifiable families (e.g. `"oct"`, or any unknown value).
  static JwkKeyType? fromJose(String kty) => switch (kty) {
    'RSA' => rsa,
    'EC' => ec,
    _ => null,
  };
}

/// The JWS signature algorithms keta_oidc accepts — an **asymmetric-only**
/// allowlist. There are exactly five values, and this enum is the whole of the
/// policy: a `JwsAlgorithm` cannot be constructed for any other `alg`.
///
/// ## Why this set, and only this set
///
/// keta_oidc is a resource server that verifies tokens signed by an identity
/// provider. It never holds the signing key, so every accepted algorithm is a
/// public-key signature.
///
/// * **`HS256` / `HS384` / `HS512` are rejected by design.** HMAC verification
///   uses the *same* secret to sign and to verify. On a resource server that
///   secret would have to be shared with it, and the classic key-confusion
///   attack — hand the server an `HS256` token signed with the *public* RSA key
///   it already trusts as an HMAC secret — turns a public key into a signing
///   oracle. Refusing to model a symmetric algorithm at all kills that entire
///   attack class at the type level: there is no `HS256` value to select, so no
///   code path can be tricked into HMAC verification.
/// * **`alg: none` is rejected by design** for the obvious reason — an
///   unsigned token is not a credential.
/// * **`PS256` / `PS384` / `PS512` are not supported initially.** RSASSA-PSS is
///   a legitimate algorithm; it is simply out of scope for this wave and can be
///   added to the allowlist later without changing the model. Its absence is a
///   judged omission, not an oversight.
///
/// Any `alg` string outside this set — `none`, an `HS*`, a `PS*`, or anything
/// unrecognised — never resolves to a value: [fromJose] returns `null` and the
/// header parser rejects the token as malformed. The rejection therefore
/// happens at the earliest possible point, before a key is ever consulted.
enum JwsAlgorithm {
  /// RSASSA-PKCS1-v1_5 using SHA-256.
  rs256('RS256', JwkKeyType.rsa),

  /// RSASSA-PKCS1-v1_5 using SHA-384.
  rs384('RS384', JwkKeyType.rsa),

  /// RSASSA-PKCS1-v1_5 using SHA-512.
  rs512('RS512', JwkKeyType.rsa),

  /// ECDSA using P-256 and SHA-256.
  es256('ES256', JwkKeyType.ec, curve: 'P-256'),

  /// ECDSA using P-384 and SHA-384.
  es384('ES384', JwkKeyType.ec, curve: 'P-384');

  const JwsAlgorithm(this.joseName, this.keyType, {this.curve});

  /// The `alg` value as it appears in a JOSE header (`"RS256"`, `"ES256"`, …).
  final String joseName;

  /// The key family this algorithm verifies with — the `kty` a matching JWK
  /// must declare.
  final JwkKeyType keyType;

  /// For an EC algorithm, the exact curve (`crv`) the key must use — `"P-256"`
  /// for [es256], `"P-384"` for [es384]. `null` for RSA algorithms, whose keys
  /// carry no curve. Binding the curve to the algorithm closes the EC analogue
  /// of key confusion: an `ES256` token can only be verified against a P-256
  /// key.
  final String? curve;

  /// The [JwsAlgorithm] for a JOSE `alg` string, or `null` when the value is
  /// outside the allowlist — including `none`, every `HS*`, every `PS*`, and any
  /// unrecognised token. A `null` result is the signal to reject the token: a
  /// disallowed algorithm can never be represented as a value.
  static JwsAlgorithm? fromJose(String alg) => switch (alg) {
    'RS256' => rs256,
    'RS384' => rs384,
    'RS512' => rs512,
    'ES256' => es256,
    'ES384' => es384,
    _ => null,
  };
}
