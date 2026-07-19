/// Pins [JwtValidator]: the algorithm allowlist and kid↔alg cross-check,
/// signature verification through the seam (including that the verifier receives
/// the exact signing-input bytes), and temporal/issuer/audience claim
/// validation with leeway.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // A fixed clock so temporal checks are deterministic.
  final fixedNow = DateTime.utc(2026, 7, 19, 12, 0, 0);
  DateTime now() => fixedNow;

  JwtValidator validator({
    Set<JwsAlgorithm>? algorithms,
    String issuer = 'https://issuer',
    String audience = 'api://resource',
    Duration leeway = const Duration(seconds: 60),
    StubVerifier? verifier,
  }) => JwtValidator(
    verifier: verifier ?? StubVerifier(),
    algorithms: algorithms ?? {JwsAlgorithm.rs256},
    issuer: issuer,
    audience: audience,
    leeway: leeway,
    now: now,
  );

  Jws rs256Token({
    Map<String, Object?>? payloadOverride,
    String alg = 'RS256',
    String? kid,
  }) {
    final payload = <String, Object?>{
      'iss': 'https://issuer',
      'aud': 'api://resource',
      'sub': 'user-1',
      'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
      ...?payloadOverride,
    };
    return Jws.parse(
      compactJws(header: {'alg': alg, 'kid': ?kid}, payload: payload),
    );
  }

  group('construction', () {
    test('an empty allowlist is an author error', () {
      expect(() => validator(algorithms: {}), throwsA(isA<ArgumentError>()));
    });
  });

  group('algorithm policy', () {
    test('a supported alg outside the allowlist is JwtAlgorithmNotAllowed', () {
      // Token is ES256 (a real algorithm), allowlist is RS256 only.
      final jws = Jws.parse(
        compactJws(
          header: {'alg': 'ES256'},
          payload: {
            'iss': 'https://issuer',
            'aud': 'api://resource',
            'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
          },
        ),
      );
      expect(
        () => validator(
          algorithms: {JwsAlgorithm.rs256},
        ).validate(jws, Jwk.fromJson(ecJwkJson())),
        throwsA(isA<JwtAlgorithmNotAllowed>()),
      );
    });

    test('a key declaring a different alg is JwtAlgorithmNotAllowed', () {
      final jws = rs256Token();
      // Key says ES256 while the token says RS256 — kid↔alg cross-check.
      final key = Jwk.fromJson(ecJwkJson(alg: 'ES256'));
      expect(
        () => validator().validate(jws, key),
        throwsA(isA<JwtAlgorithmNotAllowed>()),
      );
    });

    test('a key of the wrong type for the alg is JwtAlgorithmNotAllowed', () {
      final jws = rs256Token();
      // RS256 token, but an EC key.
      expect(
        () => validator().validate(jws, Jwk.fromJson(ecJwkJson())),
        throwsA(isA<JwtAlgorithmNotAllowed>()),
      );
    });

    test('an EC key on the wrong curve is JwtAlgorithmNotAllowed', () {
      final jws = Jws.parse(
        compactJws(
          header: {'alg': 'ES256'},
          payload: {
            'iss': 'https://issuer',
            'aud': 'api://resource',
            'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
          },
        ),
      );
      // ES256 needs P-256; give it a P-384 key.
      final key = Jwk.fromJson(ecJwkJson(crv: 'P-384'));
      expect(
        () => validator(algorithms: {JwsAlgorithm.es256}).validate(jws, key),
        throwsA(isA<JwtAlgorithmNotAllowed>()),
      );
    });
  });

  group('signature', () {
    test('a failing signature surfaces as JwtBadSignature', () {
      final verifier = StubVerifier(result: false);
      expect(
        () => validator(
          verifier: verifier,
        ).validate(rs256Token(), Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtBadSignature>()),
      );
    });

    test('the verifier receives the exact signing-input bytes', () {
      final verifier = StubVerifier();
      final token = compactJws(
        header: {'alg': 'RS256'},
        payload: {
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
        },
        signature: const [42, 43, 44],
      );
      final jws = Jws.parse(token);

      validator(verifier: verifier).validate(jws, Jwk.fromJson(rsaJwkJson()));

      expect(verifier.calls, hasLength(1));
      final call = verifier.calls.single;
      // Independently computed expectation: ASCII of "<header>.<payload>".
      final parts = token.split('.');
      expect(call.signingInput, ascii.encode('${parts[0]}.${parts[1]}'));
      expect(call.signature, Uint8List.fromList(const [42, 43, 44]));
      expect(call.algorithm, JwsAlgorithm.rs256);
    });

    test('a valid token yields claims and raw payload access', () {
      final claims = validator().validate(
        rs256Token(),
        Jwk.fromJson(rsaJwkJson()),
      );
      expect(claims.issuer, 'https://issuer');
      expect(claims.subject, 'user-1');
      expect(claims.audience, ['api://resource']);
      expect(claims.expiration, isNotNull);
      // Raw payload access for application claims.
      expect(claims.raw['sub'], 'user-1');
    });
  });

  group('temporal — exp', () {
    test('a token past exp beyond leeway is JwtExpired', () {
      final jws = rs256Token(
        payloadOverride: {
          'exp': epochSeconds(fixedNow.subtract(const Duration(minutes: 5))),
        },
      );
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtExpired>()),
      );
    });

    test('a token expired but within leeway is accepted', () {
      final jws = rs256Token(
        payloadOverride: {
          // 30s in the past, leeway 60s → still valid.
          'exp': epochSeconds(fixedNow.subtract(const Duration(seconds: 30))),
        },
      );
      expect(
        validator().validate(jws, Jwk.fromJson(rsaJwkJson())).issuer,
        'https://issuer',
      );
    });
  });

  group('temporal — nbf', () {
    test(
      'a token whose nbf is in the future beyond leeway is JwtNotYetValid',
      () {
        final jws = rs256Token(
          payloadOverride: {
            'nbf': epochSeconds(fixedNow.add(const Duration(minutes: 5))),
          },
        );
        expect(
          () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
          throwsA(isA<JwtNotYetValid>()),
        );
      },
    );

    test(
      'a token whose nbf is in the future but within leeway is accepted',
      () {
        final jws = rs256Token(
          payloadOverride: {
            'nbf': epochSeconds(fixedNow.add(const Duration(seconds: 30))),
          },
        );
        expect(
          validator().validate(jws, Jwk.fromJson(rsaJwkJson())).issuer,
          'https://issuer',
        );
      },
    );
  });

  group('issuer', () {
    test('a mismatched issuer is JwtIssuerMismatch', () {
      final jws = rs256Token(payloadOverride: {'iss': 'https://evil'});
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtIssuerMismatch>()),
      );
    });

    test('an absent issuer is JwtIssuerMismatch', () {
      // Build a payload with no iss.
      final jws = Jws.parse(
        compactJws(
          header: {'alg': 'RS256'},
          payload: {
            'aud': 'api://resource',
            'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
          },
        ),
      );
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtIssuerMismatch>()),
      );
    });
  });

  group('audience', () {
    test('aud as a matching string is accepted', () {
      final jws = rs256Token(payloadOverride: {'aud': 'api://resource'});
      expect(validator().validate(jws, Jwk.fromJson(rsaJwkJson())).audience, [
        'api://resource',
      ]);
    });

    test('aud as a non-matching string is JwtAudienceMismatch', () {
      final jws = rs256Token(payloadOverride: {'aud': 'api://other'});
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtAudienceMismatch>()),
      );
    });

    test('aud as an array containing the expected value is accepted', () {
      final jws = rs256Token(
        payloadOverride: {
          'aud': ['api://other', 'api://resource'],
        },
      );
      final claims = validator().validate(jws, Jwk.fromJson(rsaJwkJson()));
      expect(claims.audience, ['api://other', 'api://resource']);
    });

    test('aud as an array not containing the expected value is a mismatch', () {
      final jws = rs256Token(
        payloadOverride: {
          'aud': ['api://a', 'api://b'],
        },
      );
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtAudienceMismatch>()),
      );
    });

    test('aud with a non-string element is JwtMalformed', () {
      final jws = Jws.parse(
        compactJws(
          header: {'alg': 'RS256'},
          payload: {
            'iss': 'https://issuer',
            'aud': ['api://resource', 42],
            'exp': epochSeconds(fixedNow.add(const Duration(hours: 1))),
          },
        ),
      );
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('malformed claims surface at validate', () {
    test('a non-numeric exp is JwtMalformed', () {
      final jws = rs256Token(payloadOverride: {'exp': 'soon'});
      expect(
        () => validator().validate(jws, Jwk.fromJson(rsaJwkJson())),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });
}
