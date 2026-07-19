/// The internal YAML emitter (`src/yaml.dart`, not part of the public barrel —
/// same-package tests may import `src/`): non-map roots, empty/nested
/// collections, and scalar quoting/escaping, each checked for a round-trip
/// through the `yaml` package's own parser.
library;

import 'package:keta_openapi/src/yaml.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('encodeYaml — non-map roots', () {
    test('a top-level list, scalar, and null', () {
      expect(encodeYaml([1, 'a']), '- 1\n- a\n');
      expect(encodeYaml('hi'), 'hi\n');
      expect(encodeYaml(42), '42\n');
      expect(encodeYaml(null), 'null\n');
    });
  });

  group('encodeYaml — empty and nested collections', () {
    test('a top-level empty map/list round-trips (not blank → null)', () {
      expect(encodeYaml(<String, Object?>{}), '{}\n');
      expect(encodeYaml(<Object?>[]), '[]\n');
      expect(loadYaml(encodeYaml(<String, Object?>{})), <String, Object?>{});
      expect(loadYaml(encodeYaml(<Object?>[])), <Object?>[]);
    });

    test('a duplicate stringified key is rejected, not silently emitted', () {
      expect(() => encodeYaml({1: 'a', '1': 'b'}), throwsArgumentError);
    });

    test('empty {} and [] render inline', () {
      expect(
        encodeYaml({'a': <String, Object?>{}, 'b': <Object?>[]}),
        'a: {}\nb: []\n',
      );
      expect(encodeYaml([<String, Object?>{}, <Object?>[]]), '- {}\n- []\n');
    });

    test('a list nested in a list indents one level', () {
      expect(
        encodeYaml([
          ['a', 'b'],
          [1],
        ]),
        '-\n  - a\n  - b\n-\n  - 1\n',
      );
    });
  });

  group('encodeYaml — scalar quoting and escaping', () {
    test('non-finite doubles use YAML tokens', () {
      expect(encodeYaml(double.nan), '.nan\n');
      expect(encodeYaml(double.infinity), '.inf\n');
      expect(encodeYaml(double.negativeInfinity), '-.inf\n');
      expect(encodeYaml({'x': double.nan}), 'x: .nan\n');
      expect((loadYaml(encodeYaml(double.nan)) as num).isNaN, isTrue);
    });

    test('the empty string is quoted', () {
      expect(encodeYaml(''), '""\n');
      expect(encodeYaml({'k': ''}), 'k: ""\n');
    });

    test('number-like strings are quoted so they stay strings', () {
      expect(encodeYaml('42'), '"42"\n');
      expect(encodeYaml('1.0'), '"1.0"\n');
      expect(encodeYaml('-7'), '"-7"\n');
      expect(loadYaml(encodeYaml('1.0')), '1.0');
    });

    test('control chars, quotes, and backslashes are escaped', () {
      const cases = ['a\nb', 'a\rb', 'a\tb', 'say "hi"', r'C:\path'];
      expect(encodeYaml('a\nb'), '"a\\nb"\n');
      expect(encodeYaml('say "hi"'), '"say \\"hi\\""\n');
      expect(encodeYaml(r'C:\path'), '"C:\\\\path"\n');
      for (final s in cases) {
        expect(
          loadYaml(encodeYaml(s)),
          s,
          reason: 'round-trip of ${s.codeUnits}',
        );
      }
    });

    test('C0 controls and DEL without a named escape use \\xHH', () {
      // \x01 (SOH) and \x1b (ESC) have no named double-quoted escape, unlike
      // \n/\r/\t — they must come out as \xHH or the emitted scalar would
      // embed a raw control byte, which the YAML double-quoted grammar
      // forbids (the project's own parser is lenient about this, which is
      // exactly why this case needs its own pin).
      expect(encodeYaml('a\x01b\x1bc'), '"a\\x01b\\x1bc"\n');
      expect(loadYaml(encodeYaml('a\x01b\x1bc')), 'a\x01b\x1bc');
      // DEL (0x7f) is grouped with the C0 controls: also non-printable per
      // the YAML spec, also unescaped by name, also needs \xHH.
      expect(encodeYaml('a\x7fb'), '"a\\x7fb"\n');
      expect(loadYaml(encodeYaml('a\x7fb')), 'a\x7fb');
      // The named escapes are unchanged: \n/\r/\t still render as \n/\r/\t,
      // not \x0a/\x0d/\x09.
      expect(encodeYaml('a\nb\rc\td'), '"a\\nb\\rc\\td"\n');
    });

    test('reserved words are quoted (case-insensitively)', () {
      const words = [
        'true',
        'false',
        'null',
        'yes',
        'no',
        'on',
        'off',
        '~',
        'True',
        'YES',
      ];
      for (final s in words) {
        expect(encodeYaml(s), '"$s"\n');
        expect(loadYaml(encodeYaml(s)), s);
      }
    });
  });
}
