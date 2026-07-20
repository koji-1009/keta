/// `applyCanonicalFix` — materializing and reconciling the canonical DTO
/// shape: mapper/schema generation, per-member edit granularity (comment
/// preservation), idempotence, and refusal to touch anything hand-modified
/// or outside the canonical subset.
///
/// Every positive fix test follows the same symmetry: assert what the fixed
/// source contains, then assert `canonicalDiagnostics(fixed)` is empty and
/// `applyCanonicalFix(fixed)` is unchanged (idempotent).
library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('applyCanonicalFix', () {
    test('materializes missing mappers', () {
      const source = '''
import 'package:keta/keta.dart';
class UserDto {
  final String id;
  final int? age;
  UserDto({required this.id, this.age});
}
const userDtoSchema = Schema('UserDto', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}, 'age': {'type': 'integer'}}});
''';
      final fixed = applyCanonicalFix(source);
      expect(
        fixed,
        contains('factory UserDto.fromJson(Map<String, Object?> json)'),
      );
      expect(fixed, contains("id: json['id'] as String,"));
      expect(fixed, contains("age: json['age'] as int?,"));
      expect(fixed, contains("if (age != null) 'age': age,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test(
      'reconciles drift across fromJson, toJson, and the schema (M4 gate)',
      () {
        const source = '''
import 'package:keta/keta.dart';

class UserDto {
  final String id;
  final String name;
  final String? email;
  UserDto({required this.id, required this.name, this.email});
  factory UserDto.fromJson(Map<String, Object?> json) =>
      UserDto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

const userDtoSchema = Schema('UserDto', {
  'type': 'object',
  'required': ['id', 'name'],
  'properties': {'id': {'type': 'string'}, 'name': {'type': 'string'}},
});
''';
        final fixed = applyCanonicalFix(source);
        expect(fixed, contains("email: json['email'] as String?,"));
        expect(fixed, contains("if (email != null) 'email': email,"));
        // The schema constant gained the field so OpenAPI reflects it.
        expect(fixed, contains("'email': {'type': 'string'}"));
        expect(canonicalDiagnostics(fixed), isEmpty);
        expect(applyCanonicalFix(fixed), fixed);
      },
    );

    test('removing two adjacent fields does not corrupt source', () {
      const source = '''
import 'package:keta/keta.dart';

class Dto {
  final String a;
  final String d;
  Dto({required this.a, required this.d});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(a: json['a'] as String, b: json['b'] as String, c: json['c'] as String, d: json['d'] as String);
  // The stale `b`/`c` entries carry a live field value (`a`), so the value-shape
  // gate still reads toJson as enumerable and it regenerates alongside fromJson —
  // the point under test is that removing the two adjacent entries from BOTH
  // members (plus the schema) yields non-overlapping edits, not the values.
  Map<String, Object?> toJson() => {'a': a, 'b': a, 'c': a, 'd': d};
}

const dtoSchema = Schema('Dto', {
  'type': 'object',
  'required': ['a', 'b', 'c', 'd'],
  'properties': {'a': {'type': 'string'}, 'b': {'type': 'string'}, 'c': {'type': 'string'}, 'd': {'type': 'string'}},
});
''';
      final fixed = applyCanonicalFix(source);
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(fixed, isNot(contains("'b':")));
      expect(fixed, isNot(contains("'c':")));
      expect(fixed, contains("'a': a,"));
      expect(fixed, contains("'d': d,"));
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('renaming the sole field yields valid source', () {
      const source = '''
import 'package:keta/keta.dart';

class One {
  final String uuid;
  One({required this.uuid});
  factory One.fromJson(Map<String, Object?> json) => One(id: json['id'] as String);
  // The stale wire key is `id` while the value reads the live `uuid` field, so
  // toJson stays enumerable and the fix renames the key to match the field.
  Map<String, Object?> toJson() => {'id': uuid};
}

const oneSchema = Schema('One', {
  'type': 'object',
  'required': ['id'],
  'properties': {'id': {'type': 'string'}},
});
''';
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("uuid: json['uuid'] as String,"));
      expect(fixed, contains("'uuid': uuid,"));
      expect(fixed, isNot(contains("'id'")));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('does NOT forge the absent mirror of a one-way (fromJson-only) class '
        'the present mapper declares the direction; the fixer leaves it alone', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
}
''';
      // fromJson present, toJson absent, no Schema — a legitimate input-only
      // projection. The fixer must not materialize a toJson (that would forge a
      // direction the class never declared), so the output is byte-identical.
      final fixed = applyCanonicalFix(source);
      expect(fixed, source);
      expect(fixed, isNot(contains('toJson')));
      expect(canonicalDiagnostics(fixed), isEmpty);
    });

    test('a class with final fields but no canonical signal is ignored', () {
      const source = '''
class UserRepo {
  final int db;
  UserRepo(this.db);
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
      expect(applyCanonicalFix(source), source);
    });

    test('a Map<String,T> field generates valid canonical code', () {
      const source = '''
class Dto {
  final String id;
  final Map<String, int> meta;
  Dto({required this.id, required this.meta});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String, meta: const {});
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final fixed = applyCanonicalFix(source);
      expect(
        fixed,
        contains("meta: (json['meta'] as Map).cast<String, int>()"),
      );
      expect(fixed, contains("'meta': meta,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('preserves an enum property refinement and adds nested-DTO deps', () {
      const source = '''
import 'package:keta/keta.dart';

class Address {
  final String city;
  Address({required this.city});
  factory Address.fromJson(Map<String, Object?> json) => Address(city: json['city'] as String);
  Map<String, Object?> toJson() => {'city': city};
}

class Dto {
  final String role;
  final Address address;
  Dto({required this.role, required this.address});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(role: json['role'] as String);
  Map<String, Object?> toJson() => {'role': role};
}

const dtoSchema = Schema('Dto', {
  'type': 'object',
  'required': ['role'],
  'properties': {'role': {'type': 'string', 'enum': ['admin', 'member']}},
});
''';
      final fixed = applyCanonicalFix(source);
      // enum refinement preserved verbatim
      expect(fixed, contains("'enum': ['admin', 'member']"));
      // nested DTO gets a \$ref AND deps (from one model)
      expect(fixed, contains("'address':"));
      expect(fixed, contains('#/components/schemas/Address'));
      expect(fixed, contains('deps: [addressSchema]'));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('leaves a hand-modified toJson untouched', () {
      expect(
        applyCanonicalFix(handModifiedToJsonCustom),
        handModifiedToJsonCustom,
      );
    });
  });

  group('applyCanonicalFix — generation edges', () {
    test('an unresolvable field type leaves the class untouched', () {
      const source = '''
class Dto {
  final DateTime when;
  Dto({required this.when});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(when: DateTime.now());
}
''';
      expect(applyCanonicalFix(source), source);
    });

    test('collection and nullable non-primitive fields generate mappers', () {
      const source = '''
enum Role { admin, member }
class Item {
  final String n;
  Item({required this.n});
  factory Item.fromJson(Map<String, Object?> json) => Item(n: json['n'] as String);
  Map<String, Object?> toJson() => {'n': n};
}
class Dto {
  final List<Role> roles;
  final List<Item> items;
  final Map<String, Role> roleMap;
  final Map<String, Item> itemMap;
  final Role? maybeRole;
  final Item? maybeItem;
  final List<Item>? maybeList;
  final Map<String, Item>? maybeMap;
  Dto({required this.roles, required this.items, required this.roleMap, required this.itemMap, this.maybeRole, this.maybeItem, this.maybeList, this.maybeMap});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(roles: const [], items: const [], roleMap: const {}, itemMap: const {});
  // Both mappers are present but drift (fromJson reads no keys, toJson is empty),
  // so BOTH regenerate — exercising fromJson AND toJson generation across the
  // full type matrix. (A one-way class would leave its absent side alone.)
  Map<String, Object?> toJson() => {};
}
''';
      final fixed = applyCanonicalFix(source);
      expect(
        fixed,
        contains(
          "(json['roles'] as List).map((e) => Role.values.byName(e as String)).toList()",
        ),
      );
      expect(
        fixed,
        contains(
          "(json['items'] as List).map((e) => Item.fromJson(e as Map<String, Object?>)).toList()",
        ),
      );
      expect(
        fixed,
        contains(
          "(json['roleMap'] as Map).map((k, v) => MapEntry(k as String, Role.values.byName(v as String)))",
        ),
      );
      expect(
        fixed,
        contains(
          "(json['itemMap'] as Map).map((k, v) => MapEntry(k as String, Item.fromJson(v as Map<String, Object?>)))",
        ),
      );
      expect(
        fixed,
        contains(
          "maybeRole: json['maybeRole'] == null ? null : Role.values.byName(json['maybeRole'] as String)",
        ),
      );
      expect(
        fixed,
        contains("if (maybeRole != null) 'maybeRole': maybeRole!.name,"),
      );
      expect(
        fixed,
        contains("if (maybeItem != null) 'maybeItem': maybeItem!.toJson(),"),
      );
      expect(
        fixed,
        contains(
          "if (maybeList != null) 'maybeList': maybeList!.map((e) => e.toJson()).toList(),",
        ),
      );
      expect(
        fixed,
        contains(
          "if (maybeMap != null) 'maybeMap': maybeMap!.map((k, v) => MapEntry(k, v.toJson())),",
        ),
      );
      expect(fixed, contains("'roles': roles.map((e) => e.name).toList(),"));
      expect(
        fixed,
        contains("'itemMap': itemMap.map((k, v) => MapEntry(k, v.toJson())),"),
      );
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('double fields go through num.toDouble', () {
      const source = '''
class Dto {
  final double price;
  final double? rate;
  Dto({required this.price, this.rate});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(price: 0);
}
''';
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("price: (json['price'] as num).toDouble(),"));
      expect(
        fixed,
        contains(
          "rate: json['rate'] == null ? null : (json['rate'] as num).toDouble(),",
        ),
      );
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('a schema-only drift is flagged by check and regenerates the Schema '
        'constant (regression: check used to be green here while fix would '
        'rewrite the Schema — CI shipped a stale OpenAPI document; check now '
        'reports keta_schema_drift for exactly what fix reconciles)', () {
      const source = '''
import 'package:keta/keta.dart';
class Dto {
  final String id;
  final String? email;
  Dto({required this.id, this.email});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, email: json['email'] as String?);
  Map<String, Object?> toJson() => {'id': id, if (email != null) 'email': email};
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}}});
''';
      // The mappers round-trip correctly, so no mapper drift — but the Schema
      // is missing `email`, so check must report the schema drift the fix will
      // reconcile (previously this asserted `isEmpty`, enshrining the gap).
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_schema_drift');
      expect(d.single.message, contains('fields not in schema: email'));
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("'email': {'type': 'string'}"));
      // After the fix, check is clean and the fix is idempotent.
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('duplicate declarations trip the overlap guard', () {
      // Both `Dup` classes resolve to the one `dupSchema`, whose `stale`
      // property drifts from their single `id` field, so each class emits a
      // regenerating edit over the same schema range — the overlapping edits the
      // guard exists to catch. (The schema must actually drift for both to touch
      // it: under D-2's per-member granularity a matching schema is left alone.)
      const source = '''
import 'package:keta/keta.dart';
class Dup { final String id; Dup({required this.id}); }
class Dup { final String id; Dup({required this.id}); }
const dupSchema = Schema('Dup', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}, 'stale': {'type': 'string'}}});
''';
      expect(() => applyCanonicalFix(source), throwsStateError);
    });
  });

  group('applyCanonicalFix — stale-key repair', () {
    test('fix repairs a stale fromJson key when toJson is already correct', () {
      // Repro for the check/fix asymmetry: toJson was renamed but fromJson
      // still reads the old wire key. The diagnostic already reports this
      // (see canonical_check_test.dart's "canonical flags a fromJson that
      // reads the wrong key", which shares this exact fixture); the fix must
      // actually repair it rather than leave the source unchanged. This test
      // also stands in for the fix-shape gate ("the fix-shape gate must keep
      // recognizing what check recognizes") and the fallback-gate negative
      // ("the fallback gate did not over-reject") — both guarded the same
      // repair on this same minimal fixture.
      expect(canonicalDiagnostics(staleFromJsonKeyOnly), hasLength(1));
      final fixed = applyCanonicalFix(staleFromJsonKeyOnly);
      expect(fixed, isNot(staleFromJsonKeyOnly));
      expect(fixed, contains("uuid: json['uuid'] as String,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('fix repairs a stale toJson key when fromJson is already correct '
        '(the reverse)', () {
      const source = '''
class Dto {
  final String uuid;
  Dto({required this.uuid});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(uuid: json['uuid'] as String);
  Map<String, Object?> toJson() => {'id': uuid};
}
''';
      expect(canonicalDiagnostics(source), hasLength(1));
      final fixed = applyCanonicalFix(source);
      expect(fixed, isNot(source));
      expect(fixed, contains("'uuid': uuid,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });
  });

  group('applyCanonicalFix — refusals it must not touch', () {
    test('a hand-modified fromJson with a back-compat alias key is left '
        'byte-identical by the fix, and produces no diagnostic (regression: '
        'the drift trigger was once widened to read fromJson keys with no '
        'canonical-shape gate, so this alias-preserving fromJson was silently '
        'collapsed to the naive one-liner, deleting the user_id branch)', () {
      const source = '''
class UserDto {
  final String id;
  final String name;
  UserDto({required this.id, required this.name});
  factory UserDto.fromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? json['user_id']) as String;
    return UserDto(id: id, name: json['name'] as String);
  }
  Map<String, Object?> toJson() => {'id': id, 'name': name};
}
''';
      // The fix must refuse to touch it: byte-identical output.
      expect(applyCanonicalFix(source), source);
      // The diagnostic layer must agree it's unverified — it must not tell
      // the user to run a fix that will refuse to do anything. Mirroring
      // the existing "hand-modified toJson is not verified" behavior
      // (silence, not a drift warning that recommends `keta_lints:fix`),
      // canonicalDiagnostics reports nothing for this class.
      expect(canonicalDiagnostics(source), isEmpty);
    });
  });

  group('applyCanonicalFix — preserves what it must not touch', () {
    // The positional-ctor "fix leaves it untouched" fact is pinned in
    // canonical_check_test.dart's "a positional-ctor DTO with drift still
    // fires keta_canonical_drift..." test, which asserts this exact no-op on
    // this exact fixture alongside the message-content pin — a duplicate of
    // that assertion in isolation would add no coverage.

    test('fix leaves nested-list and nullable-element fields untouched', () {
      const source = '''
class Dto {
  final List<List<int>> grid;
  final List<int?> holes;
  Dto({required this.grid, required this.holes});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(grid: const [], holes: const []);
}
''';
      expect(applyCanonicalFix(source), source);
    });

    test('fix preserves top-level schema keys (no data loss)', () {
      const source = '''
import 'package:keta/keta.dart';
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id', 'name'], 'properties': {'id': {'type': 'string'}, 'name': {'type': 'string'}}, 'description': 'A very important DTO'});
''';
      final fixed = applyCanonicalFix(source);
      // The drifted toJson is regenerated, but the schema's description survives.
      expect(fixed, contains("'description': 'A very important DTO'"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('fix escapes \$ in a field name and converges', () {
      // A Schema-declared DTO with neither mapper (the materialize-from-scratch
      // case), so the fixer generates BOTH mappers AND the Schema properties
      // from the field model — exercising the `\$` escaping on every generated
      // key (a one-way class would leave one side ungenerated).
      const source = '''
import 'package:keta/keta.dart';
class Dto {
  final String a\$b;
  Dto({required this.a\$b});
}
const dtoSchema = Schema('Dto', {'type': 'object'});
''';
      final fixed = applyCanonicalFix(source);
      parseString(content: fixed, throwIfDiagnostics: true); // compiles
      expect(canonicalDiagnostics(fixed), isEmpty); // re-lints clean
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });
  });

  group('applyCanonicalFix — per-member granularity (D-2)', () {
    test('a schema-only drift leaves an inline comment inside toJson '
        'byte-for-byte (the mappers are not touched)', () {
      const source = '''
import 'package:keta/keta.dart';
class Dto {
  final String id;
  final String email;
  Dto({required this.id, required this.email});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, email: json['email'] as String);
  Map<String, Object?> toJson() => {
        'id': id,
        // keep me
        'email': email,
      };
}
const dtoSchema = Schema('Dto', {'type': 'object', 'required': ['id', 'email'], 'properties': {'id': {'type': 'string'}}});
''';
      // Only the Schema drifts (missing `email`); the mappers round-trip.
      final d = canonicalDiagnostics(source);
      expect(d.single.rule, 'keta_schema_drift');
      final fixed = applyCanonicalFix(source);
      // The Schema is reconciled...
      expect(fixed, contains("'email': {'type': 'string'}"));
      // ...and the inline comment inside toJson survives verbatim.
      expect(
        fixed,
        contains(
          "        'id': id,\n"
          '        // keep me\n'
          "        'email': email,",
        ),
      );
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a toJson-only drift leaves an inline comment inside fromJson '
        'byte-for-byte', () {
      const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(
        id: json['id'] as String,
        // keep me
        name: json['name'] as String,
      );
  Map<String, Object?> toJson() => {'id': id};
}
''';
      final fixed = applyCanonicalFix(source);
      // fromJson (not drifted) keeps its comment...
      expect(
        fixed,
        contains(
          '        // keep me\n'
          "        name: json['name'] as String,",
        ),
      );
      // ...while the drifted toJson gains the missing field.
      expect(fixed, contains("'name': name,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('a fromJson type-drift does not rewrite toJson (its inline comment '
        'survives)', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as int);
  Map<String, Object?> toJson() => {
        // keep me
        'id': id,
      };
}
''';
      // Keys all match; only the fromJson cast drifts.
      final d = canonicalDiagnostics(source);
      expect(d.single.rule, 'keta_type_drift');
      final fixed = applyCanonicalFix(source);
      // fromJson's cast is repaired...
      expect(fixed, contains("id: json['id'] as String,"));
      // ...and toJson's comment is untouched.
      expect(
        fixed,
        contains(
          '        // keep me\n'
          "        'id': id,",
        ),
      );
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('the drifted member itself loses its inline comment but keeps its doc '
        'comment (the documented, accepted loss)', () {
      const source = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  /// Serializes to the wire map.
  Map<String, Object?> toJson() => {
        // inline note
        'id': id,
      };
}
''';
      final fixed = applyCanonicalFix(source);
      // The doc comment on the regenerated member survives...
      expect(fixed, contains('/// Serializes to the wire map.'));
      // ...its inline comment does not (its body is what changed)...
      expect(fixed, isNot(contains('// inline note')));
      // ...and the drift is reconciled.
      expect(fixed, contains("'name': name,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });
  });

  group('applyCanonicalFix — enhanced enum (D-1)', () {
    // A hand-written enhanced enum plus a DTO that uses it, both canonical.
    const source = '''
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

    test('the fix repairs a sibling field drift while keeping the enhanced '
        'enum mapper (fromWire/.wire), not the name-based form', () {
      // Same DTO but toJson forgot the `id` field: only toJson drifts.
      final drifted = source.replaceFirst(
        "Map<String, Object?> toJson() => {'id': id, 'role': role.wire};",
        "Map<String, Object?> toJson() => {'role': role.wire};",
      );
      final d = canonicalDiagnostics(drifted);
      expect(d.single.rule, 'keta_canonical_drift');
      final fixed = applyCanonicalFix(drifted);
      // The regenerated toJson still uses the wire accessor, and fromJson (not
      // rewritten) still uses fromWire.
      expect(fixed, contains("'role': role.wire,"));
      expect(fixed, contains('role: Role.fromWire('));
      expect(fixed, isNot(contains('role.name')));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });
  });

  group('enum-accessor drift (fix consistency)', () {
    // Same enhanced enum as canonical_check_test.dart's 'enum-accessor drift'
    // group (kept local since it's an inline literal, not a shared support
    // constant — the two files pin different halves of the same contract).
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

    test('the manufactured inconsistency is repaired to a consistent pair: a '
        'sibling toJson key-drift no longer regenerates toJson alone (→ wire) '
        'while leaving fromJson on the name accessor', () {
      // toJson both drops `id` (key drift) AND writes role via `.name`; fromJson
      // reads role via `values.byName`. The old per-member fix would rewrite
      // only toJson (→ role.wire), stranding fromJson on the name accessor and
      // making the DTO throw ArgumentError on its own output.
      const source =
          '$enhanced'
          '''
class UserDto {
  final String id;
  final Role role;
  UserDto({required this.id, required this.role});
  factory UserDto.fromJson(Map<String, Object?> json) =>
      UserDto(id: json['id'] as String, role: Role.values.byName(json['role'] as String));
  Map<String, Object?> toJson() => {'role': role.name};
}
''';
      final fixed = applyCanonicalFix(source);
      // The pair is consistent: BOTH sides speak wire. The load-bearing
      // assertion is that fromJson was regenerated too (no `values.byName`
      // survives) — the axis that catches the manufactured hazard.
      expect(fixed, contains('role: Role.fromWire('));
      expect(fixed, contains("'role': role.wire,"));
      expect(fixed, isNot(contains('values.byName')));
      expect(fixed, isNot(contains('role.name')));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed);
    });
  });
}
