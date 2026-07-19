/// `canonicalDiagnostics` — the check-side contract for the canonical DTO
/// shape: which rule fires (missing mapper, mapper drift, schema drift, type
/// drift, enum-accessor drift), what the message says, and the refusal
/// gating that steers a user to hand-fix (naming the real blocker) instead of
/// recommending a `keta_lints:fix` run that would silently no-op.
library;

import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('canonicalDiagnostics', () {
    test('a well-formed DTO is clean', () {
      const source = '''
class UserDto {
  final String id;
  final int? age;
  UserDto({required this.id, this.age});
  factory UserDto.fromJson(Map<String, Object?> json) =>
      UserDto(id: json['id'] as String, age: json['age'] as int?);
  Map<String, Object?> toJson() => {'id': id, if (age != null) 'age': age};
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
    });

    test(
      'a DTO (by Schema signal) without mappers is keta_canonical_missing',
      () {
        const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
}
const pointSchema = Schema('Point', {'type': 'object', 'required': ['x', 'y'], 'properties': {'x': {'type': 'integer'}, 'y': {'type': 'integer'}}});
''';
        final d = canonicalDiagnostics(source);
        expect(d, hasLength(1));
        expect(d.single.rule, 'keta_canonical_missing');
        expect(d.single.message, contains('Point'));
      },
    );

    test('a mismatched toJson is keta_canonical_drift', () {
      const source = '''
class Bad {
  final String id;
  final String name;
  Bad({required this.id, required this.name});
  factory Bad.fromJson(Map<String, Object?> j) =>
      Bad(id: j['id'] as String, name: j['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      expect(d.single.message, contains('name'));
    });

    test('a non-DTO class is ignored', () {
      const source = 'class Service { void doThing() {} }';
      expect(canonicalDiagnostics(source), isEmpty);
    });
  });

  group('canonicalDiagnostics — alternate branches', () {
    test('an extra toJson key is reported as drift', () {
      // The extra key's value is a live field (`id`), so the entry is still
      // plainly enumerable (the value-shape gate only refuses values the fixer
      // could not re-emit); the extra WIRE KEY `legacy` is the genuine drift.
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id, 'legacy': id};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      expect(d.single.message, contains('toJson keys not fields: legacy'));
    });

    test('abstract and sealed carriers are never DTOs', () {
      const source = '''
abstract class A {
  final String id;
  A({required this.id});
  factory A.fromJson(Map<String, Object?> json) => throw UnimplementedError();
}
sealed class S {
  Map<String, Object?> toJson();
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a hand-modified toJson is not verified', () {
      expect(canonicalDiagnostics(handModifiedToJsonCustom), isEmpty);
    });

    test(
      'a hand-modified fromJson is not verified (symmetric with toJson)',
      () {
        const source = '''
class Weird {
  final String id;
  Weird(this.id);
  factory Weird.fromJson(Map<String, Object?> json) {
    return Weird(json['id'] as String);
  }
  Map<String, Object?> toJson() => {'id': id};
}
''';
        expect(canonicalDiagnostics(source), isEmpty);
      },
    );

    test('canonical flags a fromJson that reads the wrong key', () {
      final d = canonicalDiagnostics(staleFromJsonKeyOnly);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      expect(d.single.message, contains('fromJson reads unknown keys: id'));
      expect(d.single.message, contains('fields not read by fromJson: uuid'));
    });
  });

  group('canonicalDiagnostics — schema drift', () {
    test('check flags an EXTRA schema property fix would remove (schema drift '
        'in the other direction)', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}, 'stale': {'type': 'string'}}});
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_schema_drift');
      expect(d.single.message, contains('schema properties not fields: stale'));
      // And the fix removes exactly that property, converging to a clean check.
      final fixed = applyCanonicalFix(source);
      expect(fixed, isNot(contains("'stale'")));
      expect(canonicalDiagnostics(fixed), isEmpty);
    });

    test('a Schema whose properties match the fields is clean (negative: no '
        'false schema drift)', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id, 'name': name};
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id', 'name'], 'properties': {'id': {'type': 'string'}, 'name': {'type': 'string'}}});
''';
      expect(canonicalDiagnostics(source), isEmpty);
    });
  });

  group('canonicalDiagnostics — refusal recommendations name the real blocker, '
      'never a no-op fix', () {
    test('a positional-ctor DTO missing a mapper is told to materialize by '
        'hand, not to run a fix that refuses positional ctors (regression: the '
        'keta_canonical_missing message unconditionally recommended '
        'keta_lints:fix, which does nothing here)', () {
      const source = '''
class P {
  final String a;
  final String b;
  P(this.a, this.b);
  Map<String, Object?> toJson() => {'a': a, 'b': b};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('materialize it by hand'));
      expect(d.single.message, contains('positional constructor'));
      // It must not recommend running the fix, because the fix would refuse it.
      expect(d.single.message, isNot(contains('run keta_lints:fix')));
      expect(applyCanonicalFix(source), source); // proof the fix is a no-op
    });

    test('a DTO missing a mapper with an unresolvable field type is told to '
        'materialize by hand, naming the unsupported type', () {
      const source = '''
class D {
  final DateTime when;
  final String id;
  D({required this.when, required this.id});
  Map<String, Object?> toJson() => {'when': when.toIso8601String(), 'id': id};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('materialize it by hand'));
      expect(
        d.single.message,
        contains('field type outside the canonical subset'),
      );
      expect(d.single.message, isNot(contains('run keta_lints:fix')));
      expect(applyCanonicalFix(source), source); // proof the fix is a no-op
    });

    test('a fixable DTO missing a mapper still recommends keta_lints:fix '
        '(negative: the gate did not over-suppress the recommendation)', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Ok {
  final String id;
  Ok({required this.id});
}
const okSchema = Schema('Ok', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}}});
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('run keta_lints:fix'));
      // And the fix genuinely materializes the mapper (not a no-op).
      expect(applyCanonicalFix(source), isNot(source));
    });

    test('a positional-ctor DTO with drift still fires keta_canonical_drift '
        'but is told to reconcile by hand, not to run a fix that refuses it '
        '(the missing-message gating now covers the drift message too)', () {
      const source = '''
class P {
  final String a;
  final String b;
  P(this.a, this.b);
  factory P.fromJson(Map<String, Object?> json) => P(json['a'] as String, json['b'] as String);
  Map<String, Object?> toJson() => {'a': a};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      // The finding still fires — a broken round-trip must be seen regardless
      // of whether the auto-fixer can repair it.
      expect(d.single.message, contains('has drifted'));
      expect(d.single.message, contains('fields not in toJson: b'));
      // But the recommendation flips to by-hand and names the blocker.
      expect(d.single.message, contains('reconcile it by hand'));
      expect(d.single.message, contains('positional constructor'));
      expect(d.single.message, isNot(contains('run keta_lints:fix')));
      expect(applyCanonicalFix(source), source); // proof the fix is a no-op
    });

    test(
      'a fixable DTO with drift still recommends keta_lints:fix (negative: '
      'the drift-recommendation gate did not over-suppress the fix hint)',
      () {
        const source = '''
class Bad {
  final String id;
  final String name;
  Bad({required this.id, required this.name});
  factory Bad.fromJson(Map<String, Object?> j) =>
      Bad(id: j['id'] as String, name: j['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
        final d = canonicalDiagnostics(source);
        expect(d, hasLength(1));
        expect(d.single.rule, 'keta_canonical_drift');
        expect(d.single.message, contains('run keta_lints:fix'));
        // And the fix genuinely reconciles the mapper (not a no-op).
        expect(applyCanonicalFix(source), isNot(source));
      },
    );
  });

  group(
    'canonicalDiagnostics — inheritance is a safe refusal, never destructive',
    () {
      test('a DTO subclass with an inherited key in toJson is neither flagged '
          'nor rewritten (regression: extends was ignored, so the inherited key '
          'was a false drift and the fix regenerated toJson dropping it)', () {
        const source = '''
class Base {
  final String id;
  Base({required this.id});
  factory Base.fromJson(Map<String, Object?> json) => Base(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
class Child extends Base {
  final String name;
  Child({required super.id, required this.name});
  factory Child.fromJson(Map<String, Object?> json) =>
      Child(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id, 'name': name};
}
''';
        // Child declares only `name`, but its toJson carries the inherited `id`;
        // without skipping subclasses that reads as `toJson keys not fields: id`.
        expect(canonicalDiagnostics(source), isEmpty);
        // The fix must not regenerate Child.toJson (which would drop 'id').
        expect(applyCanonicalFix(source), source);
      });
    },
  );

  group(
    'canonicalDiagnostics — spread/for/computed-key literals are hand-authored',
    () {
      test(
        'a toJson with a spread element is treated as hand-modified: no false '
        'drift and the fixer does not flatten it (regression: the spread was '
        'read as an incomplete key set)',
        () {
          const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id, ...extra()};
  Map<String, Object?> extra() => {'name': name};
}
''';
          expect(canonicalDiagnostics(source), isEmpty);
          expect(applyCanonicalFix(source), source);
        },
      );

      test(
        'a toJson with a collection-for element is treated as hand-modified',
        () {
          const source = '''
class Dto {
  final String id;
  final List<String> keys;
  Dto({required this.id, required this.keys});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, keys: const []);
  Map<String, Object?> toJson() => {'id': id, for (final k in keys) k: 1};
}
''';
          expect(canonicalDiagnostics(source), isEmpty);
          expect(applyCanonicalFix(source), source);
        },
      );

      test('a toJson with a computed (non-literal) key is treated as '
          'hand-modified', () {
        const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
  Map<String, Object?> toJson() => {(id.isEmpty ? 'a' : 'b'): id};
}
''';
        expect(canonicalDiagnostics(source), isEmpty);
        expect(applyCanonicalFix(source), source);
      });

      test(
        'a plain map literal with a genuine drift is still reported (negative: '
        'the spread guard did not blanket-suppress drift)',
        () {
          const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
          final d = canonicalDiagnostics(source);
          expect(d, hasLength(1));
          expect(d.single.rule, 'keta_canonical_drift');
          expect(d.single.message, contains('fields not in toJson: name'));
        },
      );
    },
  );

  group('canonicalDiagnostics — a toJson value the fixer cannot re-emit is '
      'hand-authored (value-shape gate)', () {
    test('a getter-backed entry is neither flagged nor rewritten (regression: '
        'the key-only gate read fullName as an extra key, reported drift, and '
        'the fix silently deleted the computed entry — a wire change)', () {
      const source = '''
class Dto {
  final String first;
  final String last;
  Dto({required this.first, required this.last});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(first: json['first'] as String, last: json['last'] as String);
  String get fullName => first + last;
  Map<String, Object?> toJson() => {'first': first, 'last': last, 'fullName': fullName};
}
''';
      // fullName is a getter, not a final field, so its value is one the field
      // model cannot re-emit — the whole toJson is hand-authored. No drift that
      // steers the user to a fix, and the fix is byte-for-byte a no-op.
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a computed-expression value is hand-authored too (no false drift, no '
        'destructive fix)', () {
      const source = '''
class Dto {
  final int price;
  final int tax;
  Dto({required this.price, required this.tax});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(price: json['price'] as int, tax: json['tax'] as int);
  Map<String, Object?> toJson() => {'price': price, 'tax': tax, 'total': price + tax};
}
''';
      // `price + tax` is rooted at no single field, so the field model cannot
      // re-emit it — hand-authored, left alone.
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a genuine missing-field drift with all-field-rooted values still '
        'reports and fixes exactly as before (the gate did not over-reject the '
        'enumerable case)', () {
      const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      expect(d.single.message, contains('fields not in toJson: name'));
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("'name': name,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });
  });

  group('type drift', () {
    test('a fromJson cast that disagrees with the field type is keta_type_drift '
        'and the fix regenerates the cast from the field type (check/fix '
        'symmetry, keys unchanged)', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as int);
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final d = canonicalDiagnostics(source);
      // Keys all line up (fromJson reads 'id', toJson writes 'id', field 'id'),
      // so the ONLY finding is the type axis.
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_type_drift');
      expect(
        d.single.message,
        contains('fromJson casts as int but the field is String'),
      );
      expect(d.single.message, contains('run keta_lints:fix'));
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("id: json['id'] as String,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('an int? field whose fromJson casts as int (an optionality slip) is '
        'type drift, and the fix restores the nullable cast', () {
      const source = '''
class Dto {
  final int? age;
  Dto({this.age});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(age: json['age'] as int);
  Map<String, Object?> toJson() => {if (age != null) 'age': age};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_type_drift');
      expect(d.single.message, contains('casts as int but the field is int?'));
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("age: json['age'] as int?,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a correct enum field is not misread as type drift: the inner '
        'transport `as String` is not the field cast (no false positive)', () {
      const source = '''
enum Role { admin, member }
class Dto {
  final Role role;
  Dto({required this.role});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(role: Role.values.byName(json['role'] as String));
  Map<String, Object?> toJson() => {'role': role.name};
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
    });

    test('a class that drifts on both keys and a cast reports both rule ids '
        'with distinct stable ids, and the fix reconciles both', () {
      const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as int, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final d = canonicalDiagnostics(source);
      final rules = d.map((e) => e.rule).toSet();
      expect(rules, containsAll({'keta_canonical_drift', 'keta_type_drift'}));
      // Separate findings carry separate stable ids (the same reason schema
      // drift has its own id).
      expect(d.map((e) => e.id).toSet(), hasLength(d.length));
      final fixed = applyCanonicalFix(source);
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a non-fixable class (positional ctor) is not flagged for type drift, '
        'so nothing is recommended that the fixer would refuse', () {
      const source = '''
class P {
  final String a;
  P(this.a);
  factory P.fromJson(Map<String, Object?> json) => P(json['a'] as int);
  Map<String, Object?> toJson() => {'a': a};
}
''';
      // The cast (`as int`) disagrees with `String a`, but the positional ctor
      // makes the class non-fixable; flagging type drift here would point at a
      // fix that no-ops. Silence, matching the other refusal gates.
      expect(
        canonicalDiagnostics(source).any((d) => d.rule == 'keta_type_drift'),
        isFalse,
      );
      expect(applyCanonicalFix(source), source);
    });
  });

  group('canonicalDiagnostics — enhanced enum (D-1)', () {
    // A hand-written enhanced enum plus a DTO that uses it, both canonical.
    const source = '''
import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
enum Role {
  admin('admin'),
  superUser('super-user');
  const Role(this.wire);
  final String wire;
  static Role fromWire(String wire) => values.firstWhere(
        (v) => v.wire == wire,
        orElse: () => throw BadRequest('unknown Role wire value: \$wire'),
      );
}
class UserDto {
  final String id;
  final Role role;
  UserDto({required this.id, required this.role});
  factory UserDto.fromJson(Map<String, Object?> json) =>
      UserDto(id: json['id'] as String, role: Role.fromWire(json['role'] as String));
  Map<String, Object?> toJson() => {'id': id, 'role': role.wire};
}
const userDtoSchema = Schema('UserDto', {'type': 'object', 'required': ['id', 'role'], 'properties': {'id': {'type': 'string'}, 'role': {r'\$ref': '#/components/schemas/Role'}}});
''';

    test('an enhanced enum is not itself flagged, and a DTO using it via '
        'fromWire/.wire is clean', () {
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });
  });

  group('enum-accessor drift', () {
    // An enhanced (wire-mapped) enum whose wire strings differ from its Dart
    // names — so `.name`/`values.byName` and `.wire`/`fromWire` are NOT
    // interchangeable, and a DTO that picks the wrong pair breaks the wire.
    const enhanced = '''
import 'package:keta/keta.dart';
enum Role {
  admin('admin'),
  superUser('super-user');
  const Role(this.wire);
  final String wire;
  static Role fromWire(String wire) => values.firstWhere(
        (v) => v.wire == wire,
        orElse: () => throw BadRequest('unknown Role wire value: \$wire'),
      );
}
''';

    test('the blind spot now fires: an enhanced enum read through the '
        'name-based accessor drifts on keta_type_drift, and the fix repairs '
        'BOTH mappers to the wire accessor', () {
      const source =
          '$enhanced'
          '''
class UserDto {
  final String id;
  final Role role;
  UserDto({required this.id, required this.role});
  factory UserDto.fromJson(Map<String, Object?> json) =>
      UserDto(id: json['id'] as String, role: Role.values.byName(json['role'] as String));
  Map<String, Object?> toJson() => {'id': id, 'role': role.name};
}
''';
      // Keys all line up, and there is no bare-cast drift, so the only finding
      // is the enum-accessor axis — previously invisible (zero diagnostics,
      // no-op fix). It reports under keta_type_drift (a contract drift).
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_type_drift');
      expect(
        d.single.message,
        contains('role: fromJson uses the wrong enum accessor'),
      );
      expect(
        d.single.message,
        contains('role: toJson uses the wrong enum accessor'),
      );
      final fixed = applyCanonicalFix(source);
      // Both mappers now route through the wire vocabulary.
      expect(fixed, contains('role: Role.fromWire('));
      expect(fixed, contains("'role': role.wire,"));
      expect(fixed, isNot(contains('values.byName')));
      expect(fixed, isNot(contains('role.name')));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a plain (non-enhanced) enum via .name/values.byName stays clean — no '
        'false positive on the accessor axis', () {
      const source = '''
enum Role { admin, member }
class Dto {
  final Role role;
  Dto({required this.role});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(role: Role.values.byName(json['role'] as String));
  Map<String, Object?> toJson() => {'role': role.name};
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a nullable enhanced enum via fromWire/!.wire (behind the null guard) '
        'is clean — the guard and null-assert shapes are recognized', () {
      const source =
          '$enhanced'
          '''
class Dto {
  final Role? role;
  Dto({this.role});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(role: json['role'] == null ? null : Role.fromWire(json['role'] as String));
  Map<String, Object?> toJson() => {if (role != null) 'role': role!.wire};
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a nullable enhanced enum read via the name accessor still drifts and '
        'is repaired (the null-guard/!-assert paths carry the axis too)', () {
      const source =
          '$enhanced'
          '''
class Dto {
  final Role? role;
  Dto({this.role});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(role: json['role'] == null ? null : Role.values.byName(json['role'] as String));
  Map<String, Object?> toJson() => {if (role != null) 'role': role!.name};
}
''';
      expect(canonicalDiagnostics(source).single.rule, 'keta_type_drift');
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains('Role.fromWire('));
      expect(fixed, contains('role!.wire'));
      expect(fixed, isNot(contains('values.byName')));
      expect(fixed, isNot(contains('role!.name')));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });
  });

  group('schema drift is independent of the mappers', () {
    test('a spread (hand-modified) toJson no longer suppresses a stale-Schema '
        'finding: check reports keta_schema_drift and fix reconciles the '
        'Schema while leaving the refused mapper untouched', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id, 'name': name, ...extra};
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id', 'name'], 'properties': {'id': {'type': 'string'}, 'stale': {'type': 'string'}}});
''';
      // The spread makes toJson unrecognizable (the fixer refuses the mappers),
      // but the Schema-vs-fields comparison is independent — so the stale
      // `stale` property is still flagged (previously: zero diagnostics).
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_schema_drift');
      expect(d.single.message, contains('fields not in schema: name'));
      expect(d.single.message, contains('run keta_lints:fix'));
      final fixed = applyCanonicalFix(source);
      // The Schema is reconciled...
      expect(fixed, isNot(contains("'stale'")));
      expect(fixed, contains("'name': {'type': 'string'}"));
      // ...while the hand-modified toJson (its spread) is left byte-untouched.
      expect(fixed, contains('...extra'));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a positional-ctor DTO with ONLY schema drift is told to run the fix '
        'for the Schema (fix #3 made Schema repair ctor-independent), NOT to '
        'reconcile by hand naming the ctor blocker', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class P {
  final String a;
  final String b;
  P(this.a, this.b);
  factory P.fromJson(Map<String, Object?> json) => P(json['a'] as String, json['b'] as String);
  Map<String, Object?> toJson() => {'a': a, 'b': b};
}
const pSchema = Schema('P', {'type': 'object', 'required': ['a', 'b'], 'properties': {'a': {'type': 'string'}, 'stale': {'type': 'string'}}});
''';
      // The positional ctor blocks the MAPPER repairs, but the Schema repair is
      // independent, so the advice must recommend the fix — not send the user
      // to do it by hand behind a ctor blocker that no longer applies here.
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_schema_drift');
      expect(d.single.message, contains('run keta_lints:fix'));
      expect(d.single.message, isNot(contains('positional constructor')));
      final fixed = applyCanonicalFix(source);
      expect(fixed, isNot(contains("'stale'")));
      expect(fixed, contains("'b': {'type': 'string'}"));
      // The positional mappers are left exactly as written.
      expect(fixed, contains("P(json['a'] as String, json['b'] as String)"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test(
      'an unresolvable field type still blocks the Schema repair (negative: '
      'isSchemaFixable is not a blanket yes) — the advice names the blocker',
      () {
        const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class D {
  final DateTime when;
  final String id;
  D({required this.when, required this.id});
  factory D.fromJson(Map<String, Object?> json) =>
      D(when: DateTime.parse(json['when'] as String), id: json['id'] as String);
  Map<String, Object?> toJson() => {'when': when.toIso8601String(), 'id': id};
}
const dSchema = Schema('D', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}}});
''';
        final d = canonicalDiagnostics(source);
        final schemaDrift = d.where((e) => e.rule == 'keta_schema_drift');
        expect(schemaDrift, hasLength(1));
        expect(
          schemaDrift.single.message,
          contains('field type outside the canonical subset'),
        );
        expect(
          schemaDrift.single.message,
          isNot(contains('run keta_lints:fix')),
        );
        // And the fix must not touch the Schema (regenerating from the resolvable
        // subset would drop the `when` property).
        final fixed = applyCanonicalFix(source);
        expect(fixed, isNot(contains("'when': {")));
      },
    );
  });

  group('inline fallback fromJson', () {
    test('an inline `??` back-compat alias is treated as hand-modified: no '
        'destructive recommendation, and the fix leaves fromJson byte-identical '
        '(the block-form promise now holds for the inline spelling too)', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: (json['id'] ?? json['legacy_id']) as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
      // No "unknown keys: legacy_id" nag, no fix recommendation that would
      // delete the alias.
      expect(canonicalDiagnostics(source), isEmpty);
      // The fix refuses to touch it: byte-identical output.
      expect(applyCanonicalFix(source), source);
    });

    // The genuinely-canonical single-key counterpart to this fallback gate
    // (proving the gate did not over-reject) is pinned in
    // canonical_fix_test.dart's "applyCanonicalFix — stale-key repair" group,
    // which already exercises this exact fixture (staleFromJsonKeyOnly) end
    // to end (check + fix + idempotence).
  });

  group('missing-mapper message names the sibling drift', () {
    test('missing toJson + a drifted (present) fromJson names BOTH axes, since '
        'one fix run rewrites both', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as int);
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('no toJson method'));
      expect(d.single.message, contains('fromJson has also drifted'));
      expect(d.single.message, contains('run keta_lints:fix'));
      // And the fix genuinely rewrites both: it materializes toJson AND repairs
      // the stale fromJson cast.
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("id: json['id'] as String,"));
      expect(fixed, contains('Map<String, Object?> toJson()'));
      expect(canonicalDiagnostics(fixed), isEmpty);
    });

    test('missing toJson + a clean (present) fromJson names only the missing '
        'side (negative: no spurious sibling mention)', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
}
''';
      final d = canonicalDiagnostics(source);
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('no toJson method'));
      expect(d.single.message, isNot(contains('has also drifted')));
    });
  });
}
