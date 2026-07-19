/// Pins [Jwk] parsing: RSA and EC shapes, strict base64url components, carried
/// metadata (kid/alg/use/key_ops), and rejection of unusable keys.
library;

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('RSA', () {
    test('parses n and e into raw component bytes', () {
      final jwk = Jwk.fromJson(rsaJwkJson(kid: 'k1', alg: 'RS256'));
      expect(jwk.keyType, JwkKeyType.rsa);
      expect(jwk.kid, 'k1');
      expect(jwk.algorithm, JwsAlgorithm.rs256);
      expect(jwk.modulus, isNotNull);
      expect(jwk.exponent, isNotNull);
      expect(jwk.curve, isNull);
      expect(jwk.x, isNull);
    });

    test('a missing "n" is malformed', () {
      expect(
        () => Jwk.fromJson({
          'kty': 'RSA',
          'e': b64u(const [1, 0, 1]),
        }),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('a component that is not strict base64url is malformed', () {
      expect(
        () => Jwk.fromJson({'kty': 'RSA', 'n': 'has=padding', 'e': 'AQAB'}),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('EC', () {
    test('parses crv/x/y', () {
      final jwk = Jwk.fromJson(ecJwkJson(kid: 'e1', alg: 'ES256'));
      expect(jwk.keyType, JwkKeyType.ec);
      expect(jwk.curve, 'P-256');
      expect(jwk.x, isNotNull);
      expect(jwk.y, isNotNull);
      expect(jwk.modulus, isNull);
    });

    test('an unsupported curve is malformed', () {
      expect(
        () => Jwk.fromJson(ecJwkJson(crv: 'P-521')),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('a missing "crv" is malformed', () {
      expect(
        () => Jwk.fromJson({
          'kty': 'EC',
          'x': b64u(const [1]),
          'y': b64u(const [2]),
        }),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('metadata and validation', () {
    test('an unknown kty is malformed', () {
      expect(
        () => Jwk.fromJson({'kty': 'oct', 'k': 'secret'}),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('a missing kty is malformed', () {
      expect(() => Jwk.fromJson({'n': 'x'}), throwsA(isA<JwtMalformed>()));
    });

    test(
      'a declared alg outside the allowlist is retained as null, not fatal',
      () {
        // HS256 is not an accepted algorithm, but a key declaring it still parses
        // — key parsing is not the policy gate; the token's own alg is.
        final jwk = Jwk.fromJson(rsaJwkJson(alg: 'HS256'));
        expect(jwk.algorithm, isNull);
      },
    );

    test('key_ops is carried, and a non-array key_ops is malformed', () {
      final jwk = Jwk.fromJson({
        ...rsaJwkJson(),
        'use': 'sig',
        'key_ops': ['verify'],
      });
      expect(jwk.use, 'sig');
      expect(jwk.keyOps, ['verify']);

      expect(
        () => Jwk.fromJson({...rsaJwkJson(), 'key_ops': 'verify'}),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('Jwk.parse decodes JSON text', () {
      final jwk = Jwk.parse(
        '{"kty":"RSA","n":"${b64u(const [7, 7])}","e":"AQAB"}',
      );
      expect(jwk.keyType, JwkKeyType.rsa);
    });
  });
}
