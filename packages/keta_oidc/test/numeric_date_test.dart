/// Pins that a hostile-but-valid-JSON NumericDate (`exp`/`nbf`/`iat`) is
/// rejected as [JwtMalformed], never as a raw [Error] that would escape the
/// validator and become a 500: a non-finite value (`1e400` → Infinity) or one
/// outside DateTime's representable microsecond range (`9.9e18`, huge negative).
library;

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // Every registered NumericDate claim goes through the same guard.
  const numericDateClaims = ['exp', 'nbf', 'iat'];

  group('JwtClaims.fromJson rejects unrepresentable NumericDates', () {
    for (final claim in numericDateClaims) {
      test('$claim = Infinity (the JSON literal 1e400) is malformed', () {
        expect(
          () => JwtClaims.fromJson({claim: double.infinity}),
          throwsA(isA<JwtMalformed>()),
        );
      });

      test('$claim = -Infinity is malformed', () {
        expect(
          () => JwtClaims.fromJson({claim: double.negativeInfinity}),
          throwsA(isA<JwtMalformed>()),
        );
      });

      test('$claim = NaN is malformed', () {
        expect(
          () => JwtClaims.fromJson({claim: double.nan}),
          throwsA(isA<JwtMalformed>()),
        );
      });

      test('$claim = 9.9e18 (seconds beyond DateTime range) is malformed', () {
        expect(
          () => JwtClaims.fromJson({claim: 9.9e18}),
          throwsA(isA<JwtMalformed>()),
        );
      });

      test('$claim = a huge negative value is malformed', () {
        expect(
          () => JwtClaims.fromJson({claim: -9.9e18}),
          throwsA(isA<JwtMalformed>()),
        );
      });
    }

    test('a large-but-representable NumericDate still parses', () {
      // ~year 2286, well inside range: not rejected.
      final claims = JwtClaims.fromJson({'exp': 9999999999});
      expect(claims.expiration, isNotNull);
    });
  });

  group(
    'the hostile value surfaces through the validator, not as an Error',
    () {
      test('exp: 1e400 (raw JSON) validates to JwtMalformed, not a 500', () {
        // Build the token from raw JSON text so the literal `1e400` reaches the
        // JSON decoder and becomes Infinity — a Map + jsonEncode could not.
        final jws = Jws.parse(
          compactJwsRawPayload(
            header: {'alg': 'RS256'},
            payloadJson:
                '{"iss":"https://issuer","aud":"api://resource","exp":1e400}',
          ),
        );
        final validator = JwtValidator(
          verifier: StubVerifier(),
          algorithms: {JwsAlgorithm.rs256},
          issuer: 'https://issuer',
          audience: 'api://resource',
        );
        expect(
          () => validator.validate(jws, Jwk.fromJson(rsaJwkJson())),
          throwsA(isA<JwtMalformed>()),
        );
      });
    },
  );
}
