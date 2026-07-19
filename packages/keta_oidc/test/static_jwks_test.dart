/// Pins [StaticJwks]: resolve by exact kid and single-key fallback, the
/// identical-instance identity guarantee, and JwtUnknownKey on a miss.
library;

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('resolve returns the identical Jwk instance across calls', () async {
    final source = StaticJwks.parse(
      jwksJson([rsaJwkJson(kid: 'k1'), rsaJwkJson(kid: 'k2')]),
    );
    final a = await source.resolve(headerWith(kid: 'k1'));
    final b = await source.resolve(headerWith(kid: 'k1'));
    expect(identical(a, b), isTrue);
  });

  test('a kid with no matching key is JwtUnknownKey', () {
    final source = StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'k1')]));
    expect(
      () => source.resolve(headerWith(kid: 'nope')),
      throwsA(isA<JwtUnknownKey>()),
    );
  });

  test('a kid-less token resolves against a single-key set', () async {
    final source = StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'only')]));
    final jwk = await source.resolve(headerWith());
    expect(jwk.kid, 'only');
  });

  test('a kid-less token against a multi-key set is JwtUnknownKey', () {
    final source = StaticJwks.parse(
      jwksJson([rsaJwkJson(kid: 'a'), rsaJwkJson(kid: 'b')]),
    );
    expect(() => source.resolve(headerWith()), throwsA(isA<JwtUnknownKey>()));
  });

  test('StaticJwks never throws JwksUnavailable', () async {
    // A miss is always JwtUnknownKey, never "unavailable" — there is no I/O.
    final source = StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'k1')]));
    await expectLater(
      source.resolve(headerWith(kid: 'x')),
      throwsA(isA<JwtUnknownKey>()),
    );
  });

  test('exposes the parsed set including skipped entries', () {
    final source = StaticJwks.parse(
      jwksJson([
        rsaJwkJson(kid: 'good'),
        {'kty': 'oct', 'k': 'c2VjcmV0', 'kid': 'sym'},
      ]),
    );
    expect(source.keys.keys.map((k) => k.kid), ['good']);
    expect(source.keys.skippedCount, 1);
  });
}
