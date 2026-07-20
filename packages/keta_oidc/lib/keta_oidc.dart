/// keta_oidc — an OIDC/OAuth2 **resource server** for keta: it verifies the
/// Bearer JWTs an identity provider issues, and never issues or brokers tokens
/// itself.
///
/// This wave ships the JWT decode-and-validate core plus the
/// [SignatureVerifier] seam:
///
/// * [Jws.parse] — strict RFC 7515 compact-JWS parsing into a [JoseHeader], a
///   raw claims payload, the exact signing-input bytes, and the signature.
/// * [JwsAlgorithm] — the asymmetric-only algorithm allowlist
///   (RS256/RS384/RS512/ES256/ES384). `alg: none`, every `HS*`, and every `PS*`
///   are rejected by design (see the enum).
/// * [Jwk] — a parsed public JWK (RSA `n`/`e`, EC `crv`/`x`/`y`) holding raw
///   component bytes.
/// * [JwtClaims] — typed registered claims plus the raw payload.
/// * [SignatureVerifier] — the seam to the crypto backend; the JWT core carries
///   no crypto dependency of its own.
/// * [JwtValidator] — algorithm policy, key cross-check, signature verification,
///   and temporal/issuer/audience validation, yielding [JwtClaims].
/// * [JwtRejection] — the sealed, enumerable set of reasons a token is rejected.
///
/// Key sourcing (the JWKS layer) resolves a parsed token's header to the [Jwk]
/// to verify it with:
///
/// * [JwksSource] — the seam; [StaticJwks] (fixed keys) and [HttpJwksSource]
///   (an HTTP JWKS endpoint with OIDC Discovery, caching, and refresh
///   discipline) implement it.
/// * [JwkSet] / [SkippedJwk] — a parsed JWKS, with the unusable entries it
///   skipped surfaced rather than fatal.
/// * [JwksUnavailable] / [JwksDiscoveryException] / [JwksMalformed] — the typed,
///   non-[JwtRejection] failures of the key source itself.
///
/// keta_oidc ships no [SignatureVerifier] implementation of its own — the
/// production one, `BoringSslVerifier` (BoringSSL via `package:keta_native`),
/// lives in the separate `keta_oidc_boringssl` package, so depending on
/// keta_oidc alone never pulls in a BoringSSL build.
///
/// The middleware layer wires it all into keta's request pipeline:
///
/// * [oidc] — Bearer-JWT authentication middleware (RFC 6750): extract, resolve,
///   validate, and inject an [OidcPrincipal]; answer 401/403/503/500 otherwise.
/// * [requireScopes] — scope authorization (AND) after [oidc].
/// * [OidcPrincipal] / [oidcPrincipal] — the authenticated caller and the shared
///   [Key] a handler reads it back under.
library;

export 'src/jwks/http_jwks_source.dart'
    show HttpJwksSource, JwksDiscoveryException, JwksFetch;
export 'src/jwks/jwk_set.dart' show JwkSet, JwksMalformed, SkippedJwk;
export 'src/jwks/jwks_source.dart' show JwksSource, JwksUnavailable;
export 'src/jwks/static_jwks.dart' show StaticJwks;
export 'src/jwt/algorithm.dart' show JwkKeyType, JwsAlgorithm;
export 'src/jwt/claims.dart' show JwtClaims;
export 'src/jwt/jwk.dart' show Jwk;
export 'src/jwt/jws.dart' show JoseHeader, Jws;
export 'src/jwt/rejection.dart'
    show
        JwtAlgorithmNotAllowed,
        JwtAudienceMismatch,
        JwtBadSignature,
        JwtExpirationRequired,
        JwtExpired,
        JwtIssuerMismatch,
        JwtMalformed,
        JwtNotYetValid,
        JwtRejection,
        JwtUnknownKey;
export 'src/jwt/signature_verifier.dart' show SignatureVerifier;
export 'src/jwt/validator.dart' show JwtValidator;
export 'src/middleware/oidc.dart' show oidc, requireScopes;
export 'src/middleware/principal.dart' show OidcPrincipal, oidcPrincipal;
