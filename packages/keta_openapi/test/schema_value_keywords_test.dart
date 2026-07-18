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

  group('string — pattern is length-gated (ReDoS guard)', () {
    // A catastrophic-backtracking ("ReDoS") pattern: on a run of 'a's followed
    // by a non-matching character it backtracks exponentially, freezing the
    // isolate for tens of seconds. Every test here proves the boundary never
    // feeds it an over-long string, so it never runs at all. The generous
    // per-test timeout is a backstop: if the guard regressed and the regex did
    // run, the test would hang and this timeout would fail it fast rather than
    // stalling the suite for ~33s.
    const redos = r'^(a+)+$';

    // A string long enough that running `redos` over it would not return in any
    // tolerable time — but short enough to build instantly.
    String hostile(int length) => 'a' * length + '!';

    // The violation an over-ceiling string earns instead of being matched.
    // Built here rather than inline so the expected list holds one element, not
    // two adjacent string literals (which `no_adjacent_strings_in_list` flags).
    String ceilingViolation(int length) =>
        '\$: string length $length exceeds the pattern-validation ceiling of '
        '4096 code points';

    test('a maxLength-exceeded string skips pattern entirely (no hang, only '
        'the maxLength violation)', () {
      const s = Schema('Bounded', {
        'type': 'string',
        'maxLength': 20,
        'pattern': redos,
      });
      // Length 41 > maxLength 20: the value is condemned by maxLength, so the
      // regex is never run. Structural proof — exactly one violation, and it is
      // the maxLength one, not a pattern miss.
      expect(s.validate(hostile(40)), [
        r'$: string length 41 exceeds maxLength 20',
      ]);
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('a maxLength-satisfied string is still pattern-matched (the gate does '
        'not suppress a legitimate match)', () {
      const s = Schema('Bounded', {
        'type': 'string',
        'maxLength': 20,
        'pattern': r'\d{3}',
      });
      // Within maxLength, so pattern runs as before: a match passes, a miss is
      // a pattern violation.
      expect(s.validate('123'), isEmpty);
      expect(s.validate('ab'), [r'$: "ab" does not match pattern \d{3}']);
    });

    test(
      'a pattern with no maxLength is backstopped by the hard ceiling',
      () {
        const s = Schema('Unbounded', {'type': 'string', 'pattern': redos});
        // 5001 code points, over the 4096 ceiling and with no maxLength to gate
        // it: the regex is skipped and the over-length string is a violation. If
        // the ceiling regressed, `redos` would run over 5000 'a's and hang.
        expect(s.validate(hostile(5000)), [ceilingViolation(5001)]);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('the ceiling fires even for a value that would match (over-ceiling is '
        'condemned before the regex, not after)', () {
      const s = Schema('Unbounded', {'type': 'string', 'pattern': r'a'});
      // A string of 4097 'a's would match `a`, but it is over the ceiling, so
      // it is reported by length and never matched.
      final overCeiling = 'a' * 4097;
      expect(s.validate(overCeiling), [ceilingViolation(4097)]);
      // One code point under the ceiling: matched normally, so it passes.
      expect(s.validate('a' * 4096), isEmpty);
    });

    test(
      'a maxLength above the ceiling does not lift the ceiling',
      () {
        const s = Schema('Loose', {
          'type': 'string',
          'maxLength': 1000000,
          'pattern': redos,
        });
        // The value satisfies the author's (huge) maxLength, but the absolute
        // ceiling still gates the regex — a maxLength larger than the ceiling
        // cannot re-expose the unguarded regex.
        expect(s.validate(hostile(5000)), [ceilingViolation(5001)]);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('an uncompilable pattern is authoring damage even when the value is '
        'over-length', () {
      // The gate must not mask an authoring defect: the pattern is compiled
      // unconditionally, so a bad pattern surfaces as a StateError regardless
      // of whether the instance would have been length-gated.
      const bad = Schema('BadAndLong', {
        'type': 'string',
        'maxLength': 5,
        'pattern': '(',
      });
      expect(
        () => bad.validate('abcdefghij'),
        throwsAuthoringDefect(['"BadAndLong"', 'pattern']),
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

    test('a non-boolean uniqueItems is authoring damage even when maxItems is '
        'exceeded (the gate does not mask the defect)', () {
      // uniqueItems is validated before the maxItems gate, so a malformed value
      // still surfaces as a StateError on an over-long array.
      const bad = Schema('BadUniqLong', {
        'type': 'array',
        'maxItems': 1,
        'uniqueItems': 'yes',
      });
      expect(
        () => bad.validate([1, 2, 3]),
        throwsAuthoringDefect(['"BadUniqLong"', 'uniqueItems']),
      );
    });
  });

  group('array — maxItems gates the O(n²) uniqueItems scan', () {
    test('a maxItems-exceeded array skips the uniqueItems scan (only the '
        'maxItems violation, not a uniqueItems one)', () {
      const s = Schema('Gated', {
        'type': 'array',
        'items': {'type': 'integer'},
        'maxItems': 3,
        'uniqueItems': true,
      });
      // [1, 1, 1, 1] has a duplicate, so the scan would report a uniqueItems
      // collision — but the array exceeds maxItems, so the scan is skipped and
      // only the maxItems violation is reported. Structural proof of the gate.
      expect(s.validate([1, 1, 1, 1]), [
        r'$: array length 4 exceeds maxItems 3',
      ]);
    });

    test('a maxItems-satisfied array is still scanned for uniqueness (the gate '
        'does not suppress a legitimate collision)', () {
      const s = Schema('Gated', {
        'type': 'array',
        'items': {'type': 'integer'},
        'maxItems': 3,
        'uniqueItems': true,
      });
      // Within maxItems, so the scan runs: distinct passes, a duplicate is a
      // uniqueItems violation exactly as before.
      expect(s.validate([1, 2, 3]), isEmpty);
      expect(s.validate([1, 2, 1]), [
        r'$: array items at [0] and [2] are equal (uniqueItems)',
      ]);
    });

    test(
      'a large over-maxItems array does not pay the quadratic scan',
      () {
        const s = Schema('Gated', {
          'type': 'array',
          'items': {'type': 'integer'},
          'maxItems': 3,
          'uniqueItems': true,
        });
        // 50k distinct elements over maxItems: if the O(n²) scan ran it would
        // burn seconds (2.5e9 comparisons); the gate skips it, so this returns
        // immediately with only the maxItems violation. The timeout is the
        // backstop that fails fast if the gate regressed.
        final big = List<Object?>.generate(50000, (i) => i);
        expect(s.validate(big), [r'$: array length 50000 exceeds maxItems 3']);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group('array — uniqueItems has an absolute ceiling when maxItems is omitted', () {
    // The violation an over-ceiling array earns instead of being scanned. Built
    // in a helper so the expected list holds one element, not two adjacent
    // string literals (which `no_adjacent_strings_in_list` flags).
    String ceilingViolation(int length) =>
        '\$: array length $length exceeds the uniqueItems-validation ceiling '
        'of 8192 items';

    test(
      'an array past the ceiling with no maxItems is reported by length, not '
      'scanned',
      () {
        const s = Schema('Unbounded', {
          'type': 'array',
          'items': {'type': 'integer'},
          'uniqueItems': true,
        });
        // 150k distinct elements and NO maxItems: without the ceiling this is
        // the ~20s O(n²) DoS (1.1e10 comparisons). The ceiling reports the
        // array by length and never scans it, so this returns fast. The timeout
        // fails the test if the ceiling regressed and the scan ran.
        final big = List<Object?>.generate(150000, (i) => i);
        expect(s.validate(big), [ceilingViolation(150000)]);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('the ceiling fires even for an array that would have a collision', () {
      const s = Schema('Unbounded', {
        'type': 'array',
        'items': {'type': 'integer'},
        'uniqueItems': true,
      });
      // A duplicate sits within the first few elements, so a scan would report
      // a collision immediately — but the array is past the ceiling, so it is
      // reported by length instead. The ceiling is on the input the scan sees,
      // not on whether a violation exists.
      final big = <Object?>[
        1,
        1,
        ...List<Object?>.generate(9000, (i) => i + 2),
      ];
      expect(s.validate(big), [ceilingViolation(big.length)]);
    });

    test(
      'the ceiling boundary is exact: 8192 scanned, 8193 reported by length',
      () {
        const s = Schema('Unbounded', {
          'type': 'array',
          'items': {'type': 'integer'},
          'uniqueItems': true,
        });
        // Exactly 8192 distinct elements: at the ceiling, so the scan still runs
        // and finds no collision. One more element is over the ceiling and is
        // reported by length without being scanned. This adjacent pair pins the
        // exact `> ceiling` boundary (not `>=`), mirroring the pattern ceiling's
        // 4096/4097 pin — a regression that shifted the ceiling anywhere in
        // [8193, ...] would otherwise pass silently.
        final atCeiling = List<Object?>.generate(8192, (i) => i);
        expect(s.validate(atCeiling), isEmpty);
        final overByOne = List<Object?>.generate(8193, (i) => i);
        expect(s.validate(overByOne), [ceilingViolation(8193)]);
      },
    );

    test('a maxItems below the ceiling still governs (the ceiling is only a '
        'backstop for the omitted-maxItems case)', () {
      const s = Schema('Bounded', {
        'type': 'array',
        'items': {'type': 'integer'},
        'maxItems': 5,
        'uniqueItems': true,
      });
      // maxItems 5 is far below the ceiling: an array of 10 is condemned by
      // maxItems and the scan is gated out — the ceiling never enters into it.
      final ten = List<Object?>.generate(10, (i) => i);
      expect(s.validate(ten), [r'$: array length 10 exceeds maxItems 5']);
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
