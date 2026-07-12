import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:keta_lints/keta_lints.dart';
import 'package:keta_lints/src/dart_literal.dart';
import 'package:test/test.dart';

Map<String, Object?> get _doc => {
      'openapi': '3.1.0',
      'info': {'title': 't', 'version': '1'},
      'paths': {
        '/users/{id}': {
          'get': {
            'summary': 'get',
            'responses': {
              '200': {
                'content': {
                  'application/json': {
                    'schema': {r'$ref': '#/components/schemas/UserDto'},
                  },
                },
              },
            },
          },
        },
        '/users': {
          'post': {
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {r'$ref': '#/components/schemas/UserDto'},
                },
              },
            },
            'responses': {'200': <String, Object?>{}},
          },
        },
      },
      'components': {
        'schemas': {
          'Role': {
            'type': 'string',
            'enum': ['admin', 'member'],
          },
          'UserDto': {
            'type': 'object',
            'required': ['id', 'name', 'role', 'tags'],
            'properties': {
              'id': {'type': 'string'},
              'name': {'type': 'string'},
              'age': {'type': 'integer'},
              'role': {r'$ref': '#/components/schemas/Role'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        },
      },
    };

void main() {
  group('scaffold', () {
    final scaffold = generateScaffold(_doc);

    test('materializes the canonical DTO shape', () {
      final dtos = scaffold.dtos;
      expect(dtos, contains('enum Role { admin, member }'));
      expect(dtos, contains('class UserDto {'));
      expect(dtos, contains("id: json['id'] as String,"));
      expect(dtos, contains("age: json['age'] as int?,"));
      expect(dtos, contains("role: Role.values.byName(json['role'] as String),"));
      expect(dtos, contains("tags: (json['tags'] as List).cast<String>(),"));
      expect(dtos, contains("if (age != null) 'age': age,"));
      expect(dtos, contains("'role': role.name,"));
      expect(dtos, contains("const userDtoSchema = Schema('UserDto',"));
      expect(dtos, contains('deps: [roleSchema]'));
    });

    test('materializes typed route skeletons that throw 501', () {
      final routes = scaffold.routes;
      expect(routes, contains("app.get('/users/:id',"));
      expect(routes, contains("throw const KetaException(501, 'not implemented')"));
      expect(routes, contains('response: userDtoSchema'));
      expect(routes, contains("app.post('/users',"));
      expect(routes, contains('requestBody: userDtoSchema'));
    });

    test('materializes a DTO contract test', () {
      expect(scaffold.contractTest,
          contains("test('UserDto round-trips and validates'"));
      expect(scaffold.contractTest, contains('userDtoSchema.validate'));
    });

    test('escapes newlines and \$ in generated strings', () {
      final doc = {
        'openapi': '3.1.0',
        'info': {'title': 't', 'version': '1'},
        'paths': {
          '/x': {
            'get': {
              'summary': 'Charge \$5\nnow',
              'responses': {'200': <String, Object?>{}},
            },
          },
        },
        'components': {
          'schemas': {
            'D': {
              'type': 'object',
              'required': ['n'],
              'properties': {
                'n': {'type': 'string', 'description': 'line1\nline2'},
              },
            },
          },
        },
      };
      final s = generateScaffold(doc);
      expect(s.routes, contains(r'\$'));
      expect(s.routes, contains(r'\n'));
      expect(s.dtos, contains(r'line1\nline2'));
      expect(s.dtos, isNot(contains('line1\nline2'))); // no raw newline
    });

    test('rejects out-of-canonical constructs', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'Weird': {
                'type': 'object',
                'required': ['x'],
                'properties': {
                  'x': {'type': 'object', 'additionalProperties': true},
                },
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });
  });

  group('contractDrift', () {
    test('reports endpoints and fields present only on one side', () {
      final oracle = _doc;
      final shadow = {
        'paths': {
          '/users/{id}': {'get': <String, Object?>{}},
          '/users': {'get': <String, Object?>{}},
        },
        'components': {
          'schemas': {
            'UserDto': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'name': {'type': 'string'},
              },
            },
          },
        },
      };
      final drift = contractDrift(oracle, shadow);
      final messages = drift.map((d) => d.message).join('\n');
      expect(messages, contains('"post /users"'));
      expect(drift.any((d) => d.message.contains('UserDto.role')), isTrue);
      expect(drift.every((d) => d.rule == 'keta_contract_drift'), isTrue);
      expect(drift.first.id, hasLength(16));
    });

    test('no drift when documents agree', () {
      expect(contractDrift(_doc, _doc), isEmpty);
    });
  });

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

    test('a DTO (by Schema signal) without mappers is keta_canonical_missing',
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
    });

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

  group('applyCanonicalFix', () {
    test('materializes missing mappers', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class UserDto {
  final String id;
  final int? age;
  UserDto({required this.id, this.age});
}
const userDtoSchema = Schema('UserDto', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}, 'age': {'type': 'integer'}}});
''';
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("factory UserDto.fromJson(Map<String, Object?> json)"));
      expect(fixed, contains("id: json['id'] as String,"));
      expect(fixed, contains("age: json['age'] as int?,"));
      expect(fixed, contains("if (age != null) 'age': age,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });

    test('reconciles drift across fromJson, toJson, and the schema (M4 gate)',
        () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';

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
    });

    test('removing two adjacent fields does not corrupt source', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';

class Dto {
  final String a;
  final String d;
  Dto({required this.a, required this.d});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(a: json['a'] as String, b: json['b'] as String, c: json['c'] as String, d: json['d'] as String);
  Map<String, Object?> toJson() => {'a': a, 'b': b, 'c': c, 'd': d};
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
import 'package:keta_openapi/keta_openapi.dart';

class One {
  final String uuid;
  One({required this.uuid});
  factory One.fromJson(Map<String, Object?> json) => One(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id};
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
    });

    test('materializes a half-missing mapper pair', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
}
''';
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains('Map<String, Object?> toJson()'));
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
      expect(fixed, contains("meta: (json['meta'] as Map).cast<String, int>()"));
      expect(fixed, contains("'meta': meta,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
    });

    test('preserves an enum property refinement and adds nested-DTO deps', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';

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
    });

    test('leaves a hand-modified toJson untouched', () {
      const source = '''
class Weird {
  final String id;
  Weird(this.id);
  factory Weird.fromJson(Map<String, Object?> json) => Weird(json['id'] as String);
  Map<String, Object?> toJson() => _custom();
  Map<String, Object?> _custom() => {'id': id};
}
''';
      expect(applyCanonicalFix(source), source);
    });
  });

  group('routeDiagnostics', () {
    test('a matched capture is clean', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text(c.param('id')));
}
''';
      expect(routeDiagnostics(source), isEmpty);
    });

    test('an unused capture is keta_capture_unused', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text('x'));
}
''';
      final d = routeDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_capture_unused');
      expect(d.single.message, contains(':id'));
    });

    test('an unknown param is keta_param_unknown', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text(c.param('name')));
}
''';
      final rules = routeDiagnostics(source).map((d) => d.rule).toSet();
      expect(rules, containsAll(['keta_param_unknown', 'keta_capture_unused']));
    });
  });

  group('internalAwaitDiagnostics', () {
    test('await-free code is clean', () {
      const source = 'int add(int a, int b) => a + b;';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });

    test('an await is flagged', () {
      const source = 'Future<void> f() async { await g(); }\nFuture<void> g() async {}';
      final d = internalAwaitDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_internal_await');
    });

    test('a justified await is suppressed', () {
      const source = '''
Future<void> f() async {
  // keta:allow-await
  await g();
}
Future<void> g() async {}
''';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });
  });

  group('txOrderDiagnostics', () {
    test('use(tx()) before use(recover()) is flagged', () {
      const source = 'void register(app) { app..use(tx())..use(recover()); }';
      final d = txOrderDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_tx_outside_recover');
    });

    test('use(recover()) before use(tx()) is clean', () {
      const source = '''
void register() {
  final app = App<Env>()..use(accessLog())..use(recover())..use(tx());
}
''';
      expect(txOrderDiagnostics(source), isEmpty);
    });

    test('use(tx()) without recover() is not flagged', () {
      const source = 'void register(app) { app..use(tx()); }';
      expect(txOrderDiagnostics(source), isEmpty);
    });
  });

  group('diagnosticId', () {
    test('is stable and 16 hex chars', () {
      final a = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      final b = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a, isNot(diagnosticId('lib/y.dart', 'GET /x', 'keta_route_conflict')));
    });
  });

  group('dartLiteral', () {
    test('a single-line \$ value takes the raw-string path', () {
      expect(dartLiteral(r'$ref'), r"r'$ref'");
      expect(dartLiteral({r'$ref': '#/components/schemas/X'}),
          r"{r'$ref': '#/components/schemas/X'}");
    });
    test('escapes backslash, quote, and control chars', () {
      expect(dartLiteral(r'a\b'), r"'a\\b'");
      expect(dartLiteral("it's"), r"'it\'s'");
      expect(dartLiteral('a\rb'), r"'a\rb'");
      expect(dartLiteral('a\tb'), r"'a\tb'");
    });
    test('a value with both \$ and a quote takes the escape path', () {
      expect(dartLiteral(r"$a's"), r"'\$a\'s'");
    });
    test('a value with \$ and a backslash takes the escape path', () {
      expect(dartLiteral('\$a\\'), r"'\$a\\'");
    });
    test('a multi-line \$ value cannot be raw', () {
      expect(dartLiteral('\$a\nb'), r"'\$a\nb'");
    });
    test('dartStringLiteral shares the same edges', () {
      expect(dartStringLiteral(r'$ref'), r"r'$ref'");
      expect(dartStringLiteral("a'b\n"), r"'a\'b\n'");
    });
    test('a non-JSON value falls back to an escaped toString', () {
      expect(dartLiteral(const Duration(seconds: 1)), "'0:00:01.000000'");
    });
    test('scalars, lists, and non-string map keys', () {
      expect(dartLiteral(null), 'null');
      expect(dartLiteral([1, 'a']), "[1, 'a']");
      expect(dartLiteral({1: 'v'}), "{'1': 'v'}");
    });
  });

  group('yaml_plain', () {
    test('parses a mapping document into plain collections', () {
      final doc = loadYamlDocument(
          'info:\n  title: t\ntags:\n  - a\n  - 2\nflag: true\n');
      expect(doc['info'], {'title': 't'});
      expect(doc['info'], isA<Map<String, Object?>>());
      expect(doc['tags'], ['a', 2]);
      expect(doc['flag'], true);
    });
    test('non-string keys are stringified', () {
      expect(loadYamlDocument('1: a'), {'1': 'a'});
    });
    test('a non-mapping root is a FormatException', () {
      expect(() => loadYamlDocument('- a\n- b'), throwsFormatException);
      expect(() => loadYamlDocument('just a scalar'), throwsFormatException);
      expect(() => loadYamlDocument(''), throwsFormatException);
    });
    test('yamlToPlain passes non-YAML nodes through', () {
      expect(yamlToPlain(42), 42);
      expect(yamlToPlain(null), isNull);
    });
  });

  group('contractDrift — all directions', () {
    test('reports every drift direction with its own message', () {
      final oracle = {
        'paths': {
          '/only-oracle': {'get': <String, Object?>{}},
          '/shared': {'get': <String, Object?>{}},
        },
        'components': {
          'schemas': {
            'OnlyOracle': {
              'type': 'object',
              'properties': {
                'a': {'type': 'string'},
              },
            },
            'Shared': {
              'type': 'object',
              'properties': {
                'a': {'type': 'string'},
              },
            },
          },
        },
      };
      final shadow = {
        'paths': {
          '/shared': {'get': <String, Object?>{}, 'post': <String, Object?>{}},
          '/only-shadow': {'get': <String, Object?>{}},
        },
        'components': {
          'schemas': {
            'Shared': {
              'type': 'object',
              'properties': {
                'a': {'type': 'string'},
                'b': {'type': 'string'},
              },
            },
            'OnlyShadow': {'type': 'object', 'properties': <String, Object?>{}},
          },
        },
      };
      final drift = contractDrift(oracle, shadow);
      final messages = drift.map((d) => d.message).join('\n');
      expect(messages, contains('contract has "/only-oracle"'));
      expect(messages, contains('the code serves "/only-shadow"'));
      expect(messages, contains('the code serves "post /shared"'));
      expect(messages, contains('contract defines schema "OnlyOracle"'));
      expect(messages, contains('the code has field "Shared.b"'));
      expect(messages, contains('the code defines schema "OnlyShadow"'));
      expect(drift, hasLength(6));
    });
  });

  group('internalAwaitDiagnostics — await for', () {
    test('an await-for is flagged', () {
      const source =
          'Future<void> f(Stream<int> s) async {\n  await for (final _ in s) {}\n}';
      final d = internalAwaitDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_internal_await');
      expect(d.single.message, contains('await on line 2'));
    });
    test('a justified await-for is suppressed', () {
      const source =
          'Future<void> f(Stream<int> s) async {\n  // keta:allow-await\n  await for (final _ in s) {}\n}';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });
  });

  group('canonicalDiagnostics — alternate branches', () {
    test('a fromJson without a toJson names the toJson side', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_missing');
      expect(d.single.message, contains('toJson method'));
    });

    test('an extra toJson key is reported as drift', () {
      const source = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id, 'legacy': 1};
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
      const source = '''
class Weird {
  final String id;
  Weird(this.id);
  factory Weird.fromJson(Map<String, Object?> json) => Weird(json['id'] as String);
  Map<String, Object?> toJson() => _custom();
  Map<String, Object?> _custom() => {'id': id};
}
''';
      expect(canonicalDiagnostics(source), isEmpty);
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
}
''';
      final fixed = applyCanonicalFix(source);
      expect(
          fixed,
          contains(
              "(json['roles'] as List).map((e) => Role.values.byName(e as String)).toList()"));
      expect(
          fixed,
          contains(
              "(json['items'] as List).map((e) => Item.fromJson(e as Map<String, Object?>)).toList()"));
      expect(
          fixed,
          contains(
              "(json['roleMap'] as Map).map((k, v) => MapEntry(k as String, Role.values.byName(v as String)))"));
      expect(
          fixed,
          contains(
              "(json['itemMap'] as Map).map((k, v) => MapEntry(k as String, Item.fromJson(v as Map<String, Object?>)))"));
      expect(
          fixed,
          contains(
              "maybeRole: json['maybeRole'] == null ? null : Role.values.byName(json['maybeRole'] as String)"));
      expect(fixed, contains("if (maybeRole != null) 'maybeRole': maybeRole!.name,"));
      expect(fixed, contains("if (maybeItem != null) 'maybeItem': maybeItem!.toJson(),"));
      expect(
          fixed,
          contains(
              "if (maybeList != null) 'maybeList': maybeList!.map((e) => e.toJson()).toList(),"));
      expect(
          fixed,
          contains(
              "if (maybeMap != null) 'maybeMap': maybeMap!.map((k, v) => MapEntry(k, v.toJson())),"));
      expect(fixed, contains("'roles': roles.map((e) => e.name).toList(),"));
      expect(fixed,
          contains("'itemMap': itemMap.map((k, v) => MapEntry(k, v.toJson())),"));
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
              "rate: json['rate'] == null ? null : (json['rate'] as num).toDouble(),"));
      expect(canonicalDiagnostics(fixed), isEmpty);
    });

    test('a schema-only drift regenerates the Schema constant', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
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
      expect(canonicalDiagnostics(source), isEmpty);
      final fixed = applyCanonicalFix(source);
      expect(fixed, contains("'email': {'type': 'string'}"));
      expect(applyCanonicalFix(fixed), fixed);
    });

    test('duplicate declarations trip the overlap guard', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
class Dup { final String id; Dup({required this.id}); }
class Dup { final String id; Dup({required this.id}); }
const dupSchema = Schema('Dup', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}}});
''';
      expect(() => applyCanonicalFix(source), throwsStateError);
    });
  });

  group('generateScaffold — collection and sample edges', () {
    test('array items of enum, ref, and number materialize typed mappers', () {
      final doc = {
        'components': {
          'schemas': {
            'Role': {
              'type': 'string',
              'enum': ['admin'],
            },
            'Item': {
              'type': 'object',
              'required': ['n'],
              'properties': {
                'n': {'type': 'string'},
              },
            },
            'Holder': {
              'type': 'object',
              'required': ['roles', 'items', 'prices'],
              'properties': {
                'roles': {
                  'type': 'array',
                  'items': {r'$ref': '#/components/schemas/Role'},
                },
                'items': {
                  'type': 'array',
                  'items': {r'$ref': '#/components/schemas/Item'},
                },
                'prices': {
                  'type': 'array',
                  'items': {'type': 'number'},
                },
              },
            },
          },
        },
      };
      final dtos = generateScaffold(doc).dtos;
      expect(
          dtos,
          contains(
              "roles: (json['roles'] as List).map((e) => Role.values.byName(e as String)).toList(),"));
      expect(
          dtos,
          contains(
              "items: (json['items'] as List).map((e) => Item.fromJson(e as Map<String, Object?>)).toList(),"));
      expect(
          dtos,
          contains(
              "prices: (json['prices'] as List).map((e) => (e as num).toDouble()).toList(),"));
      expect(dtos, contains("'roles': roles.map((e) => e.name).toList(),"));
      expect(dtos, contains("'items': items.map((e) => e.toJson()).toList(),"));
    });

    test('a nested list is out of the canonical subset', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'W': {
                'type': 'object',
                'required': ['x'],
                'properties': {
                  'x': {
                    'type': 'array',
                    'items': {
                      'type': 'array',
                      'items': {'type': 'string'},
                    },
                  },
                },
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a required DTO ref yields a nested sample in the contract test', () {
      final doc = {
        'components': {
          'schemas': {
            'Inner': {
              'type': 'object',
              'required': ['n'],
              'properties': {
                'n': {'type': 'string'},
              },
            },
            'Outer': {
              'type': 'object',
              'required': ['inner'],
              'properties': {
                'inner': {r'$ref': '#/components/schemas/Inner'},
              },
            },
          },
        },
      };
      expect(generateScaffold(doc).contractTest, contains("'inner': {'n': 'x'}"));
    });
  });

  group('design-flaw fixes', () {
    test('scaffold sanitizes reserved/invalid names and empty objects', () {
      final doc = {
        'components': {
          'schemas': {
            'D': {
              'type': 'object',
              'required': ['class'],
              'properties': {
                'class': {'type': 'string'},
                'first-name': {'type': 'string'},
              },
            },
            'Empty': {'type': 'object', 'properties': <String, Object?>{}},
          },
        },
      };
      final dtos = generateScaffold(doc).dtos;
      parseString(content: dtos, throwIfDiagnostics: true); // parses cleanly
      expect(dtos, contains('String class_;')); // reserved word sanitized
      expect(dtos, contains("'class': ")); // original wire key preserved
      expect(dtos, contains('Empty();')); // empty ctor, not `Empty({})`
    });

    test('scaffold rejects recursion, name collision, and bad enum values', () {
      expect(
          () => generateScaffold({
                'components': {
                  'schemas': {
                    'Node': {
                      'type': 'object',
                      'required': ['next'],
                      'properties': {
                        'next': {r'$ref': '#/components/schemas/Node'},
                      },
                    },
                  },
                },
              }),
          throwsA(isA<ScaffoldError>()));
      expect(
          () => generateScaffold({
                'components': {
                  'schemas': {
                    'Foo': {'type': 'object', 'properties': <String, Object?>{}},
                    'foo': {'type': 'object', 'properties': <String, Object?>{}},
                  },
                },
              }),
          throwsA(isA<ScaffoldError>()));
      expect(
          () => generateScaffold({
                'components': {
                  'schemas': {
                    'E': {
                      'type': 'string',
                      'enum': ['ok', 'default'],
                    },
                  },
                },
              }),
          throwsA(isA<ScaffoldError>()));
    });

    test('drift reports a field type change and a required change', () {
      final oracle = {
        'components': {
          'schemas': {
            'U': {
              'type': 'object',
              'required': ['a'],
              'properties': {
                'a': {'type': 'string'},
                'b': {'type': 'integer'},
              },
            },
          },
        },
      };
      final shadow = {
        'components': {
          'schemas': {
            'U': {
              'type': 'object',
              'required': <String>[],
              'properties': {
                'a': {'type': 'string'},
                'b': {'type': 'string'},
              },
            },
          },
        },
      };
      final messages = contractDrift(oracle, shadow).map((d) => d.message);
      expect(messages, anyElement(contains('reconcile the type')));
      expect(messages.join('\n'), contains('"U.b"'));
      expect(messages.join('\n'), contains('"U.a"'));
    });

    test('canonical flags a fromJson that reads the wrong key', () {
      const source = '''
class Dto {
  final String uuid;
  Dto({required this.uuid});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(uuid: json['id'] as String);
  Map<String, Object?> toJson() => {'uuid': uuid};
}
''';
      final d = canonicalDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_canonical_drift');
      expect(d.single.message, contains('fromJson reads unknown keys: id'));
      expect(d.single.message, contains('fields not read by fromJson: uuid'));
    });

    test('fix leaves a positional-ctor DTO untouched', () {
      const source = '''
class P {
  final String a;
  final String b;
  P(this.a, this.b);
  factory P.fromJson(Map<String, Object?> json) => P(json['a'] as String, json['b'] as String);
  Map<String, Object?> toJson() => {'a': a};
}
''';
      expect(applyCanonicalFix(source), source);
    });

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
import 'package:keta_openapi/keta_openapi.dart';
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
    });

    test('fix escapes \$ in a field name and converges', () {
      const source = '''
class Dto {
  final String a\$b;
  Dto({required this.a\$b});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(a\$b: json['a\$b'] as String);
}
''';
      final fixed = applyCanonicalFix(source);
      parseString(content: fixed, throwIfDiagnostics: true); // compiles
      expect(canonicalDiagnostics(fixed), isEmpty); // re-lints clean
      expect(applyCanonicalFix(fixed), fixed); // idempotent
    });
  });
}
