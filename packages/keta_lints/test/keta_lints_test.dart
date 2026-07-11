import 'package:keta_lints/keta_lints.dart';
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

  group('diagnosticId', () {
    test('is stable and 16 hex chars', () {
      final a = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      final b = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a, isNot(diagnosticId('lib/y.dart', 'GET /x', 'keta_route_conflict')));
    });
  });
}
