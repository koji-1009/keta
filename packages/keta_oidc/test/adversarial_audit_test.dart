/// Adversarial audit pins (2026-07-19). Two groups:
///
/// * **FIXED** — invariants a resource server should hold that the audit found
///   keta_oidc did *not*, since fixed (rulings E-36 crit-header rejection and
///   E-37 required `exp`). Each group now asserts the corrected behavior and
///   guards against regression.
/// * **HARDENING** — doc-claimed-but-untested invariants that were verified to
///   hold; pinned so a regression is caught.
library;

import 'dart:convert';

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A minimal RSA JWK with no declared `alg` (the "JWKS omits alg" case).
Jwk _rsaKeyNoAlg() => Jwk.fromJson(rsaJwkJson());

JwtValidator _validator({
  StubVerifier? verifier,
  Set<JwsAlgorithm>? algorithms,
}) => JwtValidator(
  verifier: verifier ?? StubVerifier(),
  algorithms: algorithms ?? {JwsAlgorithm.rs256},
  issuer: 'https://issuer',
  audience: 'api://resource',
  now: () => DateTime.utc(2026, 7, 19, 12),
);

/// Builds a parsed RS256 token with the given payload (no exp unless supplied).
Jws _token(Map<String, Object?> payload) =>
    Jws.parse(compactJws(header: {'alg': 'RS256'}, payload: payload));

void main() {
  // ---------------------------------------------------------------------------
  group('FIXED (E-36): the JOSE "crit" header (RFC 7515 §4.1.11) is rejected', () {
    // RFC 7515 §4.1.11: a JWS carrying a `crit` header lists extension
    // parameters the recipient MUST understand. keta_oidc implements no crit
    // extension, so ANY `crit` marks processing it cannot honor — the token is
    // rejected at parse time (JwtMalformed). Without this, a legitimately-signed
    // token that *demands* critical processing would be silently accepted as a
    // plain bearer token, dropping a constraint the issuer intended.
    test('a token whose crit is a non-empty array is rejected', () {
      expect(
        () => Jws.parse(
          compactJws(
            header: {
              'alg': 'RS256',
              'crit': ['exp-binding'],
              'exp-binding': 'whatever',
            },
            payload: {'iss': 'https://issuer'},
          ),
        ),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('crit is rejected at parse, before any validation runs', () {
      // Otherwise-valid claims (iss/aud/exp); crit must reject it structurally,
      // so the validator is never even reached.
      expect(
        () => Jws.parse(
          compactJws(
            header: {
              'alg': 'RS256',
              'crit': ['b64'],
            },
            payload: {
              'iss': 'https://issuer',
              'aud': 'api://resource',
              'exp': epochSeconds(DateTime.utc(2026, 7, 19, 13)),
            },
          ),
        ),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('FIXED (E-37): a token with no "exp" claim is rejected', () {
    // `exp` is required, symmetric with `iss`/`aud`: RFC 9068 §4 requires it for
    // JWT access tokens, and keta_oidc's revocation story is short token
    // lifetimes (introspection is a judged absence), which a never-expiring
    // token defeats. There is no opt-out knob.
    test('no exp ⇒ JwtExpirationRequired at the validator', () {
      expect(
        () => _validator().validate(
          _token({
            'iss': 'https://issuer',
            'aud': 'api://resource',
            'sub': 'u',
          }),
          _rsaKeyNoAlg(),
        ),
        throwsA(isA<JwtExpirationRequired>()),
      );
    });

    test('a token WITH exp still validates', () {
      final claims = _validator().validate(
        _token({
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'sub': 'u',
          'exp': epochSeconds(DateTime.utc(2026, 7, 19, 13)),
        }),
        _rsaKeyNoAlg(),
      );
      expect(claims.subject, 'u');
    });
  });

  // ---------------------------------------------------------------------------
  group('HARDENING: signature is verified before any claim is read', () {
    // Doc-claimed (validator.dart "Order of checks": signature before any claim
    // is trusted) but not directly pinned. Proof: a token with BOTH a failing
    // signature AND a structurally-malformed claim must surface JwtBadSignature
    // (the signature step), never JwtMalformed (a later claims step). If claims
    // were typed first, this would be JwtMalformed.
    test(
      'bad signature + malformed claim ⇒ JwtBadSignature (not Malformed)',
      () {
        final jws = _token({
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'exp': 'not-a-number', // would be JwtMalformed if read before the sig
        });
        expect(
          () => _validator(
            verifier: StubVerifier(result: false),
          ).validate(jws, _rsaKeyNoAlg()),
          throwsA(isA<JwtBadSignature>()),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('HARDENING: a JWKS key that omits "alg" still binds by key type', () {
    // The prompt's "JWKS key omits alg" question: with no declared key alg, the
    // declared-alg cross-check is skipped, but the key-TYPE and curve checks are
    // not — so an alg-less key cannot be pressed into service for the wrong
    // algorithm family.
    test('an alg-less RSA key verifies an RS256 token (type agrees)', () {
      final claims = _validator().validate(
        _token({
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'exp': epochSeconds(DateTime.utc(2026, 7, 19, 13)),
        }),
        _rsaKeyNoAlg(),
      );
      expect(claims.issuer, 'https://issuer');
    });

    test(
      'an alg-less EC key cannot verify an RS256 token (type disagrees)',
      () {
        expect(
          () => _validator().validate(
            _token({
              'iss': 'https://issuer',
              'aud': 'api://resource',
              'exp': epochSeconds(DateTime.utc(2026, 7, 19, 13)),
            }),
            Jwk.fromJson(ecJwkJson()), // EC key, no alg
          ),
          throwsA(isA<JwtAlgorithmNotAllowed>()),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('HARDENING: duplicate JSON "alg" keys resolve last-wins', () {
    // dart:convert takes the last value for a duplicate object key. This pins
    // that behavior and shows it is not a smuggling vector: the signing input is
    // the exact header bytes, so an attacker cannot flip alg without breaking a
    // signature they cannot produce. The security-relevant direction — a
    // trailing "none" — is still rejected.
    Jws parseHeaderJson(String headerJson) => Jws.parse(
      '${b64u(utf8.encode(headerJson))}.'
      '${b64uJson(<String, Object?>{'iss': 'x'})}.${b64u(const [1])}',
    );

    test('{"alg":"none","alg":"RS256"} → RS256 (last wins)', () {
      expect(
        parseHeaderJson('{"alg":"none","alg":"RS256"}').header.algorithm,
        JwsAlgorithm.rs256,
      );
    });

    test('{"alg":"RS256","alg":"none"} → rejected (last wins = none)', () {
      expect(
        () => parseHeaderJson('{"alg":"RS256","alg":"none"}'),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('HARDENING: an embedded "jwk"/"jku" header is never used to resolve', () {
    // The classic key-injection attack embeds a key (or a URL to one) in the
    // token header. keta_oidc resolves keys ONLY from the configured JwksSource,
    // keyed on `kid`; header-embedded key material is retained in `raw` but
    // never consulted. A StaticJwks that does not hold the embedded key's kid
    // therefore misses, rather than trusting the attacker's key.
    test('resolution ignores an attacker-embedded jwk header', () async {
      final source = StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'trusted')]));
      // The token names a kid the source does not hold, and smuggles a full jwk.
      final jws = Jws.parse(
        compactJws(
          header: {
            'alg': 'RS256',
            'kid': 'attacker',
            'jwk': rsaJwkJson(kid: 'attacker'),
            'jku': 'https://attacker.example/keys',
          },
          payload: {'iss': 'https://issuer'},
        ),
      );
      await expectLater(
        source.resolve(jws.header),
        throwsA(isA<JwtUnknownKey>()),
      );
    });
  });
}
