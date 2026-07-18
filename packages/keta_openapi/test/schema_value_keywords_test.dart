/// Schema.validate's value-keyword enforcement — the "document does not lie"
/// thesis applied to the scalar/array validation keywords (`minLength`,
/// `maxLength`, `pattern`, `format`, `minimum`, `maximum`, the exclusive
/// variants, `multipleOf`, `minItems`, `maxItems`, `uniqueItems`). A keyword
/// that keta emits into the OpenAPI document must bind at the boundary: a
/// violated value is instance data (posture (2), a violation → 400), a
/// malformed keyword value is authoring damage (posture (1), a StateError →
/// 500), and a recognized validation keyword keta does not enforce is authoring
/// damage too — it would be a promise the boundary silently breaks.
library;

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

/// A schema whose sole `message` StateError contains every fragment listed.
Matcher throwsAuthoringDefect(List<String> fragments) => throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    allOf([for (final f in fragments) contains(f)]),
  ),
);

void main() {
  group('string — minLength / maxLength (Unicode code points)', () {
    const s = Schema('Str', {'type': 'string', 'minLength': 2, 'maxLength': 4});

    test('boundary lengths (== min, == max) are accepted', () {
      expect(s.validate('ab'), isEmpty);
      expect(s.validate('abcd'), isEmpty);
    });

    test('one short of min and one over max are violations', () {
      expect(s.validate('a'), [
        r'$: string length 1 is shorter than minLength 2',
      ]);
      expect(s.validate('abcde'), [r'$: string length 5 exceeds maxLength 4']);
    });

    test('length is counted in code points, not UTF-16 code units', () {
      // '😀' is one code point but two UTF-16 code units; a UTF-16 count would
      // read '😀😀😀' as length 6 and trip maxLength 4. Code points read it 3.
      const emoji = Schema('Emoji', {'type': 'string', 'maxLength': 4});
      expect(emoji.validate('😀😀😀'), isEmpty);
      expect(emoji.validate('😀😀😀😀😀'), [
        r'$: string length 5 exceeds maxLength 4',
      ]);
      // A single astral char is length 1 against minLength 1, not 2.
      const one = Schema('One', {'type': 'string', 'minLength': 1});
      expect(one.validate('😀'), isEmpty);
    });

    test(
      'a non-integer or negative bound is a schema-authoring StateError',
      () {
        const bad = Schema('BadMin', {'type': 'string', 'minLength': '2'});
        expect(
          () => bad.validate('anything'),
          throwsAuthoringDefect(['"BadMin"', 'minLength']),
        );
        const neg = Schema('NegMax', {'type': 'string', 'maxLength': -1});
        expect(
          () => neg.validate('anything'),
          throwsAuthoringDefect(['"NegMax"', 'maxLength', '-1']),
        );
      },
    );
  });

  group('string — pattern', () {
    const s = Schema('Pat', {'type': 'string', 'pattern': r'\d{3}'});

    test('matches unanchored (a partial match anywhere satisfies it)', () {
      expect(s.validate('abc123def'), isEmpty);
      expect(s.validate('123'), isEmpty);
    });

    test('a string with no match is a violation', () {
      expect(s.validate('ab'), [r'$: "ab" does not match pattern \d{3}']);
    });

    test('an anchored pattern still rejects a non-matching whole string', () {
      const anchored = Schema('Anchored', {
        'type': 'string',
        'pattern': r'^\d{3}$',
      });
      expect(anchored.validate('123'), isEmpty);
      expect(anchored.validate('x123'), [
        r'$: "x123" does not match pattern ^\d{3}$',
      ]);
    });

    test('a non-string pattern is a schema-authoring StateError', () {
      const bad = Schema('BadPat', {'type': 'string', 'pattern': 42});
      expect(
        () => bad.validate('x'),
        throwsAuthoringDefect(['"BadPat"', 'pattern']),
      );
    });

    test('an uncompilable pattern is a schema-authoring StateError', () {
      const bad = Schema('BadRegex', {'type': 'string', 'pattern': '('});
      expect(
        () => bad.validate('x'),
        throwsAuthoringDefect(['"BadRegex"', 'pattern']),
      );
    });
  });

  group('string — format (only a crisp set is enforced)', () {
    test('date-time enforces RFC 3339', () {
      const s = Schema('DT', {'type': 'string', 'format': 'date-time'});
      expect(s.validate('2026-07-18T09:30:00Z'), isEmpty);
      expect(s.validate('2026-07-18T09:30:00.123+09:00'), isEmpty);
      expect(s.validate('2026-07-18 09:30:00'), [
        r'$: "2026-07-18 09:30:00" is not a valid date-time',
      ]);
      expect(s.validate('not-a-date'), [
        r'$: "not-a-date" is not a valid date-time',
      ]);
    });

    test('date enforces RFC 3339 full-date and rejects impossible dates', () {
      const s = Schema('D', {'type': 'string', 'format': 'date'});
      expect(s.validate('2026-07-18'), isEmpty);
      expect(s.validate('2026-02-30'), [
        r'$: "2026-02-30" is not a valid date',
      ]);
      expect(s.validate('2026-13-01'), [
        r'$: "2026-13-01" is not a valid date',
      ]);
    });

    test('uuid enforces the RFC 4122 string form', () {
      const s = Schema('U', {'type': 'string', 'format': 'uuid'});
      expect(s.validate('123e4567-e89b-12d3-a456-426614174000'), isEmpty);
      expect(s.validate('123e4567e89b12d3a456426614174000'), [
        r'$: "123e4567e89b12d3a456426614174000" is not a valid uuid',
      ]);
    });

    test('an unknown format is an annotation — passed through, never a '
        'violation', () {
      // `binary` (used by the files example), `email`, `hostname`, … are not in
      // keta's enforced set: emitted, but not enforced. Any value passes.
      const binary = Schema('Bin', {'type': 'string', 'format': 'binary'});
      expect(binary.validate('anything at all'), isEmpty);
      const email = Schema('Email', {'type': 'string', 'format': 'email'});
      expect(email.validate('not-an-email'), isEmpty);
    });

    test('a non-string format is a schema-authoring StateError', () {
      const bad = Schema('BadFmt', {'type': 'string', 'format': 42});
      expect(
        () => bad.validate('x'),
        throwsAuthoringDefect(['"BadFmt"', 'format']),
      );
    });
  });

  group('number — minimum / maximum / exclusive variants', () {
    const s = Schema('Num', {'type': 'number', 'minimum': 0, 'maximum': 10});

    test('inclusive bounds accept the boundary values', () {
      expect(s.validate(0), isEmpty);
      expect(s.validate(10), isEmpty);
      expect(s.validate(5.5), isEmpty);
    });

    test('outside the inclusive bounds is a violation', () {
      expect(s.validate(-1), [r'$: -1 is less than minimum 0']);
      expect(s.validate(11), [r'$: 11 is greater than maximum 10']);
    });

    test('exclusive bounds reject the boundary values', () {
      const ex = Schema('Ex', {
        'type': 'number',
        'exclusiveMinimum': 0,
        'exclusiveMaximum': 10,
      });
      expect(ex.validate(0), [r'$: 0 is not greater than exclusiveMinimum 0']);
      expect(ex.validate(10), [r'$: 10 is not less than exclusiveMaximum 10']);
      expect(ex.validate(5), isEmpty);
    });

    test('numeric bounds bind to an integer type too', () {
      const i = Schema('IntBound', {
        'type': 'integer',
        'minimum': 1,
        'maximum': 3,
      });
      expect(i.validate(2), isEmpty);
      expect(i.validate(0), [r'$: 0 is less than minimum 1']);
    });

    test('a non-numeric bound is a schema-authoring StateError', () {
      const bad = Schema('BadBound', {'type': 'number', 'minimum': 'zero'});
      expect(
        () => bad.validate(1),
        throwsAuthoringDefect(['"BadBound"', 'minimum']),
      );
    });
  });

  group('number — multipleOf', () {
    test('an integer multiple is exact', () {
      const s = Schema('Mult', {'type': 'integer', 'multipleOf': 3});
      expect(s.validate(9), isEmpty);
      expect(s.validate(0), isEmpty);
      expect(s.validate(7), [r'$: 7 is not a multiple of 3']);
    });

    test('a fractional multipleOf survives binary floating-point error', () {
      const s = Schema('Dec', {'type': 'number', 'multipleOf': 0.1});
      // 0.3 / 0.1 == 2.9999999999999996 in IEEE-754; still a multiple.
      expect(s.validate(0.3), isEmpty);
      expect(s.validate(0.1), isEmpty);
      // 0.35 is genuinely not a multiple of 0.1.
      expect(s.validate(0.35), [r'$: 0.35 is not a multiple of 0.1']);
    });

    test('a multipleOf that is not greater than zero is authoring damage', () {
      const zero = Schema('Zero', {'type': 'number', 'multipleOf': 0});
      expect(
        () => zero.validate(1),
        throwsAuthoringDefect(['"Zero"', 'multipleOf']),
      );
      const neg = Schema('Neg', {'type': 'number', 'multipleOf': -2});
      expect(
        () => neg.validate(4),
        throwsAuthoringDefect(['"Neg"', 'multipleOf']),
      );
    });
  });

  group('array — minItems / maxItems', () {
    const s = Schema('Arr', {
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 1,
      'maxItems': 3,
    });

    test('boundary counts are accepted', () {
      expect(s.validate(['a']), isEmpty);
      expect(s.validate(['a', 'b', 'c']), isEmpty);
    });

    test('an empty array trips minItems', () {
      expect(s.validate(<Object?>[]), [
        r'$: array length 0 is shorter than minItems 1',
      ]);
    });

    test('too many elements trips maxItems', () {
      expect(s.validate(['a', 'b', 'c', 'd']), [
        r'$: array length 4 exceeds maxItems 3',
      ]);
    });

    test('an array-level keyword is reported even when an element also '
        'fails', () {
      // A too-short array with a mistyped element are two distinct facts; the
      // minItems check must not be suppressed by the element error.
      const strict = Schema('Strict', {
        'type': 'array',
        'items': {'type': 'string'},
        'minItems': 3,
      });
      final errors = strict.validate(['a', 1]);
      expect(errors, contains(r'$[1]: expected string, got integer'));
      expect(errors, contains(r'$: array length 2 is shorter than minItems 3'));
    });

    test('a non-integer minItems is a schema-authoring StateError', () {
      const bad = Schema('BadItems', {'type': 'array', 'minItems': '1'});
      expect(
        () => bad.validate(<Object?>[]),
        throwsAuthoringDefect(['"BadItems"', 'minItems']),
      );
    });
  });

  group('array — uniqueItems (deep JSON equality)', () {
    test('duplicate scalars are a violation, distinct ones pass', () {
      const s = Schema('Uniq', {
        'type': 'array',
        'items': {'type': 'integer'},
        'uniqueItems': true,
      });
      expect(s.validate([1, 2, 3]), isEmpty);
      expect(s.validate([1, 2, 1]), [
        r'$: array items at [0] and [2] are equal (uniqueItems)',
      ]);
    });

    test('equal nested objects collide by value, not identity', () {
      const s = Schema('UniqObj', {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'k': {'type': 'integer'},
          },
        },
        'uniqueItems': true,
      });
      expect(
        s.validate([
          {'k': 1},
          {'k': 2},
        ]),
        isEmpty,
      );
      expect(
        s.validate([
          {'k': 1},
          {'k': 1},
        ]),
        [r'$: array items at [0] and [1] are equal (uniqueItems)'],
      );
    });

    test('uniqueItems false imposes no constraint', () {
      const s = Schema('NotUniq', {
        'type': 'array',
        'items': {'type': 'integer'},
        'uniqueItems': false,
      });
      expect(s.validate([1, 1, 1]), isEmpty);
    });

    test('a non-boolean uniqueItems is a schema-authoring StateError', () {
      const bad = Schema('BadUniq', {'type': 'array', 'uniqueItems': 'yes'});
      expect(
        () => bad.validate(<Object?>[]),
        throwsAuthoringDefect(['"BadUniq"', 'uniqueItems']),
      );
    });
  });

  group('a wrong-typed value skips its keyword checks (no double report)', () {
    test('a number where a string is declared reports only the type error', () {
      const s = Schema('S', {
        'type': 'string',
        'minLength': 3,
        'pattern': r'\d',
      });
      expect(s.validate(42), [r'$: expected string, got integer']);
    });

    test('a zero-fraction double where an integer is declared reports only '
        'the type error, not the minimum', () {
      const s = Schema('I', {'type': 'integer', 'minimum': 10});
      expect(s.validate(5.0), [r'$: expected integer, got number']);
    });
  });

  group('type-less fragments bind keywords by the instance type', () {
    test('a string keyword applies to a string instance with no declared '
        'type', () {
      const s = Schema('NoType', {'minLength': 2});
      expect(s.validate('ab'), isEmpty);
      expect(s.validate('a'), [
        r'$: string length 1 is shorter than minLength 2',
      ]);
    });

    test('a numeric keyword applies to a numeric instance with no declared '
        'type', () {
      const s = Schema('NoType', {'minimum': 0});
      expect(s.validate(1), isEmpty);
      expect(s.validate(-1), [r'$: -1 is less than minimum 0']);
    });

    test('an array keyword applies to a list instance with no declared '
        'type', () {
      const s = Schema('NoType', {'minItems': 2});
      expect(s.validate([1, 2]), isEmpty);
      expect(s.validate([1]), [
        r'$: array length 1 is shorter than minItems 2',
      ]);
    });
  });

  group('keywords bind on nested paths and gate 400 vs 500', () {
    const user = Schema('KeyUser', {
      'type': 'object',
      'required': ['name', 'age'],
      'properties': {
        'name': {'type': 'string', 'minLength': 1, 'maxLength': 3},
        'age': {'type': 'integer', 'minimum': 0},
      },
    });

    test('a violated keyword carries the property path', () {
      expect(
        user.validate({'name': 'abcd', 'age': 5}),
        contains(r'$.name: string length 4 exceeds maxLength 3'),
      );
      expect(
        user.validate({'name': 'ok', 'age': -1}),
        contains(r'$.age: -1 is less than minimum 0'),
      );
    });

    test('a keyword violation surfaces as a BadRequest(400)', () {
      expect(
        () => user.require({'name': '', 'age': 1}),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
    });
  });

  group('recognized validation keywords keta does not enforce are authoring '
      'damage', () {
    // "What you can write takes effect; what doesn't take effect can't be
    // written." A keyword keta would emit but never apply is a promise the
    // boundary silently breaks — posture (1), a StateError, never a silent
    // pass.
    test('const', () {
      const s = Schema('WithConst', {'type': 'string', 'const': 'x'});
      expect(
        () => s.validate('y'),
        throwsAuthoringDefect(['"WithConst"', 'const']),
      );
    });

    test('allOf / anyOf / not', () {
      for (final key in ['allOf', 'anyOf', 'not']) {
        final s = Schema('With_$key', {key: <Object?>[]});
        expect(
          () => s.validate('anything'),
          throwsAuthoringDefect(['With_$key', key]),
          reason: '$key must be rejected',
        );
      }
    });

    test('minProperties / maxProperties', () {
      const s = Schema('WithMinProps', {'type': 'object', 'minProperties': 1});
      expect(
        () => s.validate(<String, Object?>{'a': 1}),
        throwsAuthoringDefect(['"WithMinProps"', 'minProperties']),
      );
    });

    test('patternProperties', () {
      const s = Schema('WithPatProps', {
        'type': 'object',
        'patternProperties': <String, Object?>{},
      });
      expect(
        () => s.validate(<String, Object?>{}),
        throwsAuthoringDefect(['"WithPatProps"', 'patternProperties']),
      );
    });

    test('an unenforced keyword sitting beside a \$ref is still caught', () {
      const target = Schema('Target', {'type': 'string'});
      const s = Schema(
        'RefPlus',
        {r'$ref': '#/components/schemas/Target', 'not': <Object?>{}},
        deps: [target],
      );
      expect(
        () => s.validate('x'),
        throwsAuthoringDefect(['"RefPlus"', 'not']),
      );
    });

    test('a pure annotation is not a validation keyword — it passes', () {
      const s = Schema('Annotated', {
        'type': 'string',
        'description': 'a label',
        'example': 'sample',
        'deprecated': true,
        'minLength': 1,
      });
      expect(s.validate('ok'), isEmpty);
      expect(s.validate(''), [
        r'$: string length 0 is shorter than minLength 1',
      ]);
    });
  });
}
