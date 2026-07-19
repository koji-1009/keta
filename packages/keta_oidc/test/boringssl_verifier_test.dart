/// End-to-end with REAL BoringSSL crypto through the whole pipeline
/// (Jws.parse → StaticJwks.resolve → JwtValidator.validate → claims) for all
/// five algorithms, plus tamper detection (signature, signing input, wrong key),
/// the wrong-size-ES256-signature path, and the identity key cache.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';
import 'support.dart';

/// One algorithm under test, with a signer and the JWKS entries for the correct
/// and a different (wrong) key.
class AlgCase {
  AlgCase({
    required this.name,
    required this.alg,
    required this.sign,
    required this.jwk,
    required this.wrongJwk,
  });

  final String name;
  final JwsAlgorithm alg;
  final Uint8List Function(Uint8List signingInput) sign;
  final Map<String, Object?> Function(String kid) jwk;
  final Map<String, Object?> Function(String kid) wrongJwk;
}

void main() {
  // Generate each key once for the whole suite (key generation is the slow bit).
  final rsa = RsaKeyPair.generate();
  final rsaWrong = RsaKeyPair.generate();
  final ec256 = EcKeyPair.generateP256();
  final ec256Wrong = EcKeyPair.generateP256();
  final ec384 = EcKeyPair.generateP384();
  final ec384Wrong = EcKeyPair.generateP384();

  final cases = <AlgCase>[
    AlgCase(
      name: 'RS256',
      alg: JwsAlgorithm.rs256,
      sign: rsa.signPkcs1Sha256,
      jwk: (kid) => rsaJwkOf(rsa, kid: kid, alg: 'RS256'),
      wrongJwk: (kid) => rsaJwkOf(rsaWrong, kid: kid, alg: 'RS256'),
    ),
    AlgCase(
      name: 'RS384',
      alg: JwsAlgorithm.rs384,
      sign: rsa.signPkcs1Sha384,
      jwk: (kid) => rsaJwkOf(rsa, kid: kid, alg: 'RS384'),
      wrongJwk: (kid) => rsaJwkOf(rsaWrong, kid: kid, alg: 'RS384'),
    ),
    AlgCase(
      name: 'RS512',
      alg: JwsAlgorithm.rs512,
      sign: rsa.signPkcs1Sha512,
      jwk: (kid) => rsaJwkOf(rsa, kid: kid, alg: 'RS512'),
      wrongJwk: (kid) => rsaJwkOf(rsaWrong, kid: kid, alg: 'RS512'),
    ),
    AlgCase(
      name: 'ES256',
      alg: JwsAlgorithm.es256,
      sign: (si) => derToRawRS(ec256.signEcdsaSha256(si), 32),
      jwk: (kid) => ecJwkOf(ec256, kid: kid, crv: 'P-256', alg: 'ES256'),
      wrongJwk: (kid) =>
          ecJwkOf(ec256Wrong, kid: kid, crv: 'P-256', alg: 'ES256'),
    ),
    AlgCase(
      name: 'ES384',
      alg: JwsAlgorithm.es384,
      sign: (si) => derToRawRS(ec384.signEcdsaSha384(si), 48),
      jwk: (kid) => ecJwkOf(ec384, kid: kid, crv: 'P-384', alg: 'ES384'),
      wrongJwk: (kid) =>
          ecJwkOf(ec384Wrong, kid: kid, crv: 'P-384', alg: 'ES384'),
    ),
  ];

  JwtValidator validatorFor(JwsAlgorithm alg) => JwtValidator(
    verifier: BoringSslVerifier(),
    algorithms: {alg},
    issuer: 'https://issuer',
    audience: 'api://resource',
  );

  Future<JwtClaims> runPipeline(
    JwksSource source,
    JwtValidator v,
    String token,
  ) async {
    final jws = Jws.parse(token);
    final key = await source.resolve(jws.header);
    return v.validate(jws, key);
  }

  for (final c in cases) {
    group(c.name, () {
      test('a validly signed token verifies and yields claims', () async {
        final token = signedToken(alg: c.name, kid: 'k1', sign: c.sign);
        final source = StaticJwks.parse(jwksJson([c.jwk('k1')]));
        final claims = await runPipeline(source, validatorFor(c.alg), token);
        expect(claims.issuer, 'https://issuer');
        expect(claims.subject, 'user-1');
      });

      test('tampered signature bytes → JwtBadSignature', () async {
        final token = signedToken(alg: c.name, kid: 'k1', sign: c.sign);
        final parts = token.split('.');
        final jws = Jws.parse(token);
        // Flip a byte of the raw signature and re-encode (length preserved, so an
        // ES* signature still passes the length check and fails in the crypto).
        final flipped = Uint8List.fromList(jws.signature);
        flipped[0] ^= 0xFF;
        final bad = '${parts[0]}.${parts[1]}.${b64u(flipped)}';
        final source = StaticJwks.parse(jwksJson([c.jwk('k1')]));
        await expectLater(
          runPipeline(source, validatorFor(c.alg), bad),
          throwsA(isA<JwtBadSignature>()),
        );
      });

      test('tampered signing input → JwtBadSignature', () async {
        final token = signedToken(alg: c.name, kid: 'k1', sign: c.sign);
        final parts = token.split('.');
        // Swap in a different payload segment; the signature no longer covers it.
        final forgedPayload = b64uJson({
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'sub': 'attacker',
          'exp': epochSeconds(DateTime.now().add(const Duration(hours: 1))),
        });
        final bad = '${parts[0]}.$forgedPayload.${parts[2]}';
        final source = StaticJwks.parse(jwksJson([c.jwk('k1')]));
        await expectLater(
          runPipeline(source, validatorFor(c.alg), bad),
          throwsA(isA<JwtBadSignature>()),
        );
      });

      test('wrong key → JwtBadSignature', () async {
        final token = signedToken(alg: c.name, kid: 'k1', sign: c.sign);
        // Same kid, but a different key's material in the JWKS.
        final source = StaticJwks.parse(jwksJson([c.wrongJwk('k1')]));
        await expectLater(
          runPipeline(source, validatorFor(c.alg), token),
          throwsA(isA<JwtBadSignature>()),
        );
      });
    });
  }

  test(
    'an ES256 signature of the wrong size → JwtBadSignature, not an exception',
    () async {
      // 96 bytes of r‖s is a P-384 width, invalid for ES256 (64). The verifier
      // fails the length check and returns false — surfacing as JwtBadSignature.
      final headerSeg = b64uJson({'alg': 'ES256', 'kid': 'k1'});
      final payloadSeg = b64uJson({
        'iss': 'https://issuer',
        'aud': 'api://resource',
        'exp': epochSeconds(DateTime.now().add(const Duration(hours: 1))),
      });
      final token = '$headerSeg.$payloadSeg.${b64u(Uint8List(96))}';
      final source = StaticJwks.parse(
        jwksJson([ecJwkOf(ec256, kid: 'k1', crv: 'P-256', alg: 'ES256')]),
      );
      await expectLater(
        runPipeline(source, validatorFor(JwsAlgorithm.es256), token),
        throwsA(isA<JwtBadSignature>()),
      );
    },
  );

  test(
    'the identity key cache: repeated verify with the same Jwk works',
    () async {
      // The same Jwk instance is imported once and then served from the Expando;
      // the second verify hits the cache. Both must succeed.
      final verifier = BoringSslVerifier();
      final token = signedToken(
        alg: 'RS256',
        kid: 'k1',
        sign: rsa.signPkcs1Sha256,
      );
      final source = StaticJwks.parse(
        jwksJson([rsaJwkOf(rsa, kid: 'k1', alg: 'RS256')]),
      );
      final jws = Jws.parse(token);
      final key = await source.resolve(jws.header);

      bool verifyOnce() => verifier.verify(
        key: key,
        algorithm: JwsAlgorithm.rs256,
        signingInput: jws.signingInput,
        signature: jws.signature,
      );

      expect(verifyOnce(), isTrue); // imports and caches the native key
      expect(verifyOnce(), isTrue); // served from the Expando cache
    },
  );

  test('a StateError surfaces when a key lacks components for the algorithm', () {
    // Directly (bypassing the validator's cross-check) hand an EC key to an RSA
    // algorithm: an author defect, thrown, not laundered into false.
    final verifier = BoringSslVerifier();
    final ecKey = Jwk.fromJson(
      ecJwkOf(ec256, kid: 'k1', crv: 'P-256', alg: 'ES256'),
    );
    expect(
      () => verifier.verify(
        key: ecKey,
        algorithm: JwsAlgorithm.rs256,
        signingInput: Uint8List.fromList(utf8.encode('x')),
        signature: Uint8List(256),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
