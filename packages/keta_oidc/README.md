# keta_oidc

An OIDC / OAuth2 **resource server** for keta: it verifies the Bearer JWTs an identity provider issues, injects the resulting principal, and authorizes on scope. It is a Ring 1 package — it builds on keta core alone — and it does exactly one side of OIDC: the side that *consumes* tokens.

keta_oidc ships no `SignatureVerifier` implementation of its own, so depending on it never pulls in a build. The production implementation, `BoringSslVerifier` (BoringSSL via `keta_native`), lives in the separate [`keta_oidc_boringssl`](../keta_oidc_boringssl) package — depending on *that* package (rather than on keta_oidc alone) is what triggers the from-source BoringSSL build.

> **Status.** All waves have landed: the JWT decode-and-validate core, the `SignatureVerifier` seam (below), JWKS fetching, the `oidc()` middleware, and the BoringSSL-backed verifier (`keta_oidc_boringssl`) all ship today.

## Why a resource server, and only that

keta_oidc validates tokens; it never mints or brokers them. A resource server holds no signing key — it trusts an issuer's public keys and checks that a presented token was signed by one of them, is unexpired, and is meant for this API. That is a small, sharp job, and keeping it small is what makes it safe.

The token-issuing side of OIDC — the Authorization Code flow, PKCE, logging a user in and out, refresh-token handling — is a **judged absence**, not a gap to fill here. It is a different program (a client / a relying party) with a different threat model, and folding it in would blur the one thing this package guarantees: that a request carrying a bad token does not get through.

## What it verifies

- **Compact JWS parsing** (RFC 7515 §3.1): exactly three base64url segments, **strict** — no padding, URL alphabet only. A header/payload that is not a JSON object, or a header without an `alg`, is rejected as malformed.
- **Asymmetric signatures only**: `RS256` / `RS384` / `RS512` / `ES256` / `ES384`. The token's algorithm must be in an explicit per-validation allowlist *and* agree with the resolved key (declared `alg`, key type, and — for EC — curve).
- **Claims** (RFC 7519): `iss` exact match, `aud` (string or array) containing the expected audience, `exp` / `nbf` with a single configurable leeway (default 60s). `sub` is surfaced but not required; `iat` is surfaced but **not** age-validated (see below). The clock is injectable.

## Judged absences

These are deliberate, argued omissions — decisions, not TODOs.

- **`HS256` / `HS384` / `HS512` (HMAC) are rejected by design.** HMAC verifies with the same secret it signs with; on a resource server that enables the classic key-confusion attack (present an `HS256` token "signed" with the server's *public* RSA key, which it trusts as an HMAC secret, turning a public key into a signing oracle). keta_oidc does not model a symmetric algorithm at all, so there is no `HS*` value to select and no code path to confuse — the attack class is dead at the type level.
- **`alg: none` is rejected by design.** An unsigned token is not a credential.
- **`PS256` / `PS384` / `PS512` (RSASSA-PSS) are not supported initially.** A legitimate algorithm, simply out of scope for now; it can be added to the allowlist later without changing the model.
- **`iat` is not validated for age.** RFC 7519 makes `iat` informational, not a validity boundary. A maximum-age knob is a non-feature here until a concrete need appears — it is not added speculatively.
- **Remote token introspection (RFC 7662) is not implemented.** Validation is local. A per-request round-trip to the IdP would tax every request with the IdP's latency and couple this server's availability to it, and introspection's main use — opaque tokens — is moot for a package that verifies JWTs. Revocation immediacy is served instead by short token lifetimes plus an out-of-band revocation-notice pattern.
- **The IdP client side (login flows) is out of scope** — see "Why a resource server, and only that".

## The `SignatureVerifier` seam

The JWT core carries **no** cryptographic dependency. The one operation that needs one — checking a signature — goes through a single interface:

```dart
abstract interface class SignatureVerifier {
  bool verify({
    required Jwk key,
    required JwsAlgorithm algorithm,
    required Uint8List signingInput,
    required Uint8List signature,
  });
}
```

- `signingInput` is the ASCII of `"<header>.<payload>"`, exactly as it arrived — the bytes to hash, never re-encoded.
- `signature` is the **raw JOSE signature**. For `ES*` that is the fixed-width `r ‖ s` concatenation JOSE mandates (RFC 7518 §3.4), *not* ASN.1/DER — a backend that needs DER converts it itself. Fixing the JOSE-side form as the thing that crosses the seam keeps backends interchangeable.
- A non-verifying signature is a **`false` return**, an ordinary outcome; a backend throws only on its own defect (a key it cannot import).

`Jwk` instances are long-lived and reused across calls; a backend may cache a derived native key keyed on `Jwk` identity (an `Expando`). The default backend is `BoringSslVerifier` (BoringSSL via `keta_native`), shipped from `keta_oidc_boringssl` rather than from this package — the seam exists so it, or any other backend, can be swapped in without touching this package.

## Error posture

Every reason a token is rejected is a `final` subtype of the sealed `JwtRejection` — malformed, algorithm-not-allowed, bad-signature, expiration-required, expired, not-yet-valid, issuer-mismatch, audience-mismatch, unknown-key. The set is closed and enumerable, so the `oidc()` middleware can map it to RFC 6750 `401` responses with an exhaustive `switch` the compiler checks. `JwtRejection` does **not** carry an HTTP status: turning a reason into a response is the middleware's job, and the JWT layer stays free of HTTP semantics. It `implements Exception` (a rejected token is an input-validation outcome to catch); author defects in this package surface as `Error` instead.

## Usage sketch

The pipeline is three separable steps — parse, resolve a key, validate — so the `kid` in the header can pick a key *before* the signature is checked:

```dart
final jws = Jws.parse(compactToken);          // structural: throws JwtMalformed
final key = await jwks.resolve(jws.header);    // JWKS: throws JwtUnknownKey
final claims = validator.validate(jws, key);   // policy + signature + claims
```

Every documented invariant here has a test in `test/`.
