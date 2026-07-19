/// Pins [JwkSet]: skipping unusable entries (not rejecting the document),
/// duplicate-kid last-wins, malformed-document detection, and lookup by exact
/// kid / single-key fallback.
library;

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('parsing a mixed document', () {
    test(
      'keeps the usable RSA and EC keys, skips the rest, does not throw',
      () {
        final set = JwkSet.parse(
          jwksJson([
            rsaJwkJson(kid: 'good-rsa'),
            ecJwkJson(kid: 'good-ec'),
            {
              'kty': 'oct',
              'k': 'c2VjcmV0',
              'kid': 'sym',
            }, // symmetric: unusable
            {...rsaJwkJson(kid: 'enc'), 'use': 'enc'}, // encryption key
            ecJwkJson(kid: 'weird', crv: 'P-521'), // unsupported curve
            {'kty': 'RSA', 'kid': 'broken'}, // missing n/e
            {
              ...rsaJwkJson(kid: 'no-verify'),
              'key_ops': ['encrypt'],
            }, // key_ops lacking "verify"
          ]),
        );

        expect(set.keys.map((k) => k.kid), ['good-rsa', 'good-ec']);
        expect(set.skippedCount, 5);
        // Each skip carries the kid it declared.
        expect(
          set.skipped.map((s) => s.kid),
          containsAll(<String>['sym', 'enc', 'weird', 'broken', 'no-verify']),
        );
      },
    );
  });

  group('key_ops', () {
    test('a key whose key_ops includes "verify" is kept', () {
      final set = JwkSet.parse(
        jwksJson([
          {
            ...rsaJwkJson(kid: 'v'),
            'key_ops': ['verify'],
          },
        ]),
      );
      expect(set.keys.map((k) => k.kid), ['v']);
      expect(set.skippedCount, 0);
    });
  });

  group('duplicate kid', () {
    test('last-wins: the later entry replaces the earlier at its position', () {
      // Two keys share kid "dup" but differ in material (different modulus).
      final first = {
        ...rsaJwkJson(kid: 'dup'),
        'n': b64u(List<int>.filled(32, 1)),
      };
      final second = {
        ...rsaJwkJson(kid: 'dup'),
        'n': b64u(List<int>.filled(32, 2)),
      };
      final set = JwkSet.parse(jwksJson([first, second]));

      // Only one key for the kid, and it is the second (its modulus is all-2s).
      expect(set.keys, hasLength(1));
      final resolved = set.lookup(headerWith(kid: 'dup'))!;
      expect(resolved.modulus!.every((b) => b == 2), isTrue);
    });
  });

  group('malformed document', () {
    test('non-JSON is JwksMalformed', () {
      expect(() => JwkSet.parse('not json'), throwsA(isA<JwksMalformed>()));
    });

    test('a top-level array is JwksMalformed', () {
      expect(() => JwkSet.parse('[]'), throwsA(isA<JwksMalformed>()));
    });

    test('no "keys" array is JwksMalformed', () {
      expect(
        () => JwkSet.parse('{"notkeys": []}'),
        throwsA(isA<JwksMalformed>()),
      );
    });

    test('an empty key set is valid (zero usable keys), not malformed', () {
      final set = JwkSet.parse(jwksJson([]));
      expect(set.keys, isEmpty);
    });
  });

  group('lookup', () {
    test('exact kid match', () {
      final set = JwkSet.parse(
        jwksJson([rsaJwkJson(kid: 'a'), rsaJwkJson(kid: 'b')]),
      );
      expect(set.lookup(headerWith(kid: 'b'))!.kid, 'b');
    });

    test('a kid with no match returns null', () {
      final set = JwkSet.parse(jwksJson([rsaJwkJson(kid: 'a')]));
      expect(set.lookup(headerWith(kid: 'zzz')), isNull);
    });

    test('no kid + exactly one key resolves that key', () {
      final set = JwkSet.parse(jwksJson([rsaJwkJson(kid: 'only')]));
      expect(set.lookup(headerWith())!.kid, 'only');
    });

    test('no kid + more than one key is ambiguous (null)', () {
      final set = JwkSet.parse(
        jwksJson([rsaJwkJson(kid: 'a'), rsaJwkJson(kid: 'b')]),
      );
      expect(set.lookup(headerWith()), isNull);
    });

    test('no kid + zero keys returns null', () {
      final set = JwkSet.parse(jwksJson([]));
      expect(set.lookup(headerWith()), isNull);
    });
  });
}
