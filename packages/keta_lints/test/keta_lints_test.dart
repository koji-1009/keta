import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:keta_lints/keta_lints.dart';
import 'package:keta_lints/src/dart_literal.dart';
import 'package:path/path.dart' as p;
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
        // A create answers 201. The scaffold has to read that from the
        // document rather than assume 200, or the code it materializes starts
        // out contradicting the contract it was generated from.
        'responses': {'201': <String, Object?>{}},
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
      expect(dtos, contains('  const UserDto({'));
      expect(dtos, contains("id: json['id'] as String,"));
      expect(dtos, contains("age: json['age'] as int?,"));
      expect(
        dtos,
        contains("role: Role.values.byName(json['role'] as String),"),
      );
      expect(dtos, contains("tags: (json['tags'] as List).cast<String>(),"));
      expect(dtos, contains("if (age != null) 'age': age,"));
      expect(dtos, contains("'role': role.name,"));
      expect(dtos, contains("const userDtoSchema = Schema('UserDto',"));
      expect(dtos, contains('deps: [roleSchema]'));
    });

    test('materializes typed route skeletons that throw 501', () {
      final routes = scaffold.routes;
      expect(routes, contains("app.get('/users/:id',"));
      expect(
        routes,
        contains("throw const NotImplementedYet('not implemented')"),
      );
      expect(routes, contains('success: Success(schema: userDtoSchema)'));
      expect(routes, contains("app.post('/users',"));
      expect(routes, contains('requestBody: userDtoSchema'));
      // The status comes from the document's own 2xx, not from the 200 slot:
      // the contract says 201, so the skeleton says 201.
      expect(routes, contains('success: Success(status: 201)'));
    });

    test('materializes a DTO contract test', () {
      expect(
        scaffold.contractTest,
        contains("test('UserDto round-trips and validates'"),
      );
      expect(scaffold.contractTest, contains('userDtoSchema.validate'));
    });

    test('a declared scheme flows into the route doc and a 401 contract test', () {
      final doc = {
        ..._doc,
        'paths': {
          '/users': {
            'post': {
              'security': [
                {'bearer': <String>[]},
              ],
              'responses': {'200': <String, Object?>{}},
            },
          },
          '/users/{id}': {
            'get': {
              'security': [
                {'bearer': <String>[]},
              ],
              'responses': {'200': <String, Object?>{}},
            },
          },
        },
      };
      final s = generateScaffold(doc);
      expect(s.routes, contains('security: [bearer]'));
      // routes.dart exposes the shared assembly point the tests and tool call.
      expect(s.routes, contains('App<Object?> buildApp()'));
      // The 401 tests drive buildApp — green by wiring enforcement there, never
      // by editing the test.
      expect(
        s.contractTest,
        contains('POST /users rejects a request without credentials'),
      );
      expect(s.contractTest, contains('TestClient(buildApp(), null)'));
      expect(s.contractTest, contains("client.post('/users')).status, 401"));
      expect(s.contractTest, contains("client.get('/users/x')).status, 401"));
      expect(s.contractTest, isNot(contains('register(app)')));
      // The tool builds through the same buildApp seam.
      expect(s.openapiTool, contains('OpenApi.fromRoutes(buildApp().routes)'));
      // Both outputs parse cleanly (test discipline: generated code is valid).
      parseString(content: s.routes, throwIfDiagnostics: true);
      parseString(content: s.contractTest, throwIfDiagnostics: true);
    });

    test('an unknown security scheme is outside the canonical subset', () {
      expect(
        () => generateScaffold({
          ..._doc,
          'paths': {
            '/x': {
              'get': {
                'security': [
                  {'oauth2': <String>[]},
                ],
                'responses': {'200': <String, Object?>{}},
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
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
      },
    );

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
      expect(
        fixed,
        contains("meta: (json['meta'] as Map).cast<String, int>()"),
      );
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
      const source =
          'Future<void> f() async { await g(); }\nFuture<void> g() async {}';
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
      expect(
        a,
        isNot(diagnosticId('lib/y.dart', 'GET /x', 'keta_route_conflict')),
      );
    });
  });

  group('dartLiteral', () {
    test('a single-line \$ value takes the raw-string path', () {
      expect(dartLiteral(r'$ref'), r"r'$ref'");
      expect(
        dartLiteral({r'$ref': '#/components/schemas/X'}),
        r"{r'$ref': '#/components/schemas/X'}",
      );
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
        'info:\n  title: t\ntags:\n  - a\n  - 2\nflag: true\n',
      );
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
    });

    test('a schema-only drift is flagged by check and regenerates the Schema '
        'constant (regression: check used to be green here while fix would '
        'rewrite the Schema — CI shipped a stale OpenAPI document; check now '
        'reports keta_schema_drift for exactly what fix reconciles)', () {
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
import 'package:keta_openapi/keta_openapi.dart';
class Dup { final String id; Dup({required this.id}); }
class Dup { final String id; Dup({required this.id}); }
const dupSchema = Schema('Dup', {'type': 'object', 'required': ['id'], 'properties': {'id': {'type': 'string'}, 'stale': {'type': 'string'}}});
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
          "roles: (json['roles'] as List).map((e) => Role.values.byName(e as String)).toList(),",
        ),
      );
      expect(
        dtos,
        contains(
          "items: (json['items'] as List).map((e) => Item.fromJson(e as Map<String, Object?>)).toList(),",
        ),
      );
      expect(
        dtos,
        contains(
          "prices: (json['prices'] as List).map((e) => (e as num).toDouble()).toList(),",
        ),
      );
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
      expect(
        generateScaffold(doc).contractTest,
        contains("'inner': {'n': 'x'}"),
      );
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

    test('scaffold rejects recursion, name collision, and colliding enum wire '
        'values', () {
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
        throwsA(isA<ScaffoldError>()),
      );
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'Foo': {'type': 'object', 'properties': <String, Object?>{}},
              'foo': {'type': 'object', 'properties': <String, Object?>{}},
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
      // A reserved word ('default') is no longer rejected — D-1 materializes it
      // as an enhanced enum (default_('default')). What IS still rejected is two
      // wire values that derive the SAME Dart identifier, since the enum would
      // otherwise silently lose a case.
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'E': {
                'type': 'string',
                'enum': ['super-user', 'super user'],
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a non-string enum value raises ScaffoldError instead of a raw '
        'TypeError', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'E': {
                'type': 'string',
                'enum': ['ok', 3],
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a type: array property without items raises ScaffoldError instead '
        'of a raw TypeError', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'D': {
                'type': 'object',
                'required': ['tags'],
                'properties': {
                  'tags': {'type': 'array'},
                },
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('other malformed oracle shapes raise ScaffoldError instead of a raw '
        'TypeError (audit of the same bare-cast class of bug)', () {
      // A components/schemas entry that is not an object.
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {'D': 'not an object'},
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
      // A property schema that is not an object.
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'D': {
                'type': 'object',
                'required': ['x'],
                'properties': {'x': true},
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
      // A "required" that is not a list of strings.
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'D': {
                'type': 'object',
                'required': 'x',
                'properties': {
                  'x': {'type': 'string'},
                },
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
      // A "properties" that is not an object.
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'D': {'type': 'object', 'properties': 'not an object'},
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
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

    test('fix repairs a stale fromJson key when toJson is already correct', () {
      // Repro for the check/fix asymmetry: toJson was renamed but fromJson
      // still reads the old wire key. The diagnostic already reports this
      // (see 'canonical flags a fromJson that reads the wrong key' above);
      // the fix must actually repair it rather than leave the source
      // unchanged.
      const source = '''
class Dto {
  final String uuid;
  Dto({required this.uuid});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(uuid: json['id'] as String);
  Map<String, Object?> toJson() => {'uuid': uuid};
}
''';
      expect(canonicalDiagnostics(source), hasLength(1));
      final fixed = applyCanonicalFix(source);
      expect(fixed, isNot(source));
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

    test('a hand-modified fromJson with a back-compat alias key is left '
        'byte-identical by the fix, and produces no diagnostic (regression: '
        'c2088e3 widened the drift trigger to read fromJson keys with no '
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

    test('a canonical fromJson with a stale key is still repaired (the case '
        'c2088e3 legitimately fixed)', () {
      const source = '''
class Dto {
  final String uuid;
  Dto({required this.uuid});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(uuid: json['id'] as String);
  Map<String, Object?> toJson() => {'uuid': uuid};
}
''';
      expect(canonicalDiagnostics(source), hasLength(1));
      final fixed = applyCanonicalFix(source);
      expect(fixed, isNot(source));
      expect(fixed, contains("uuid: json['uuid'] as String,"));
      expect(canonicalDiagnostics(fixed), isEmpty);
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

    // --- item 1: check/fix schema-drift symmetry ---------------------------

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

    // --- item 2: don't recommend a fix that would silently no-op -----------

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

    test('a fixable DTO with drift still recommends keta_lints:fix (negative: '
        'the drift-recommendation gate did not over-suppress the fix hint)', () {
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
    });

    // --- item 3: inheritance is a safe refusal, never destructive ----------

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

    // --- item 4: spread / for / computed-key literals are hand-authored ----

    test('a toJson with a spread element is treated as hand-modified: no false '
        'drift and the fixer does not flatten it (regression: the spread was '
        'read as an incomplete key set)', () {
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
    });

    test('a toJson with a collection-for element is treated as hand-modified', () {
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
    });

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

    test('a plain map literal with a genuine drift is still reported (negative: '
        'the spread guard did not blanket-suppress drift)', () {
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
    });
  });

  group('scaffold — query', () {
    test('a query parameter flows into the route doc and a 400 test', () {
      final doc = {
        ..._doc,
        'paths': {
          '/users': {
            'get': {
              'parameters': [
                {
                  'name': 'limit',
                  'in': 'query',
                  'required': true,
                  'schema': {'type': 'integer'},
                },
              ],
              'responses': {'200': <String, Object?>{}},
            },
          },
        },
      };
      final s = generateScaffold(doc);
      expect(
        s.routes,
        contains("query: [QueryParam('limit', integer, required: true)]"),
      );
      expect(
        s.contractTest,
        contains('GET /users requires its query parameters'),
      );
      expect(s.contractTest, contains("client.get('/users')).status, 400"));
      parseString(content: s.routes, throwIfDiagnostics: true);
      parseString(content: s.contractTest, throwIfDiagnostics: true);
    });
  });

  group('query lint', () {
    test('flags a c.query access not declared in RouteDoc.query', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('other', integer)]));
}
''';
      final d = queryDiagnostics(source);
      expect(d.single.rule, 'keta_query_undeclared');
      expect(d.single.message, contains('page'));
    });

    test('flags reading a required query with tryQuery (drift)', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.tryQuery<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('page', integer, required: true)]));
}
''';
      expect(queryDiagnostics(source).single.rule, 'keta_query_drift');
    });

    test('a declared, correctly-read query is clean', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('page', integer, required: true)]));
}
''';
      expect(queryDiagnostics(source), isEmpty);
    });

    test('a non-inline doc is not second-guessed', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}), doc: userDoc);
}
''';
      expect(queryDiagnostics(source), isEmpty);
    });
  });

  group('scaffold — sealed', () {
    Map<String, Object?> variant(String tag, String field) => {
      'type': 'object',
      'required': ['type', field],
      'properties': {
        'type': {'type': 'string'},
        field: {'type': 'string'},
      },
    };

    final doc = {
      'openapi': '3.1.0',
      'info': {'title': 't', 'version': '1'},
      'paths': <String, Object?>{},
      'components': {
        'schemas': {
          'Event': {
            'oneOf': [
              {r'$ref': '#/components/schemas/Created'},
              {r'$ref': '#/components/schemas/Deleted'},
            ],
            'discriminator': {
              'propertyName': 'type',
              'mapping': {
                'created': '#/components/schemas/Created',
                'deleted': '#/components/schemas/Deleted',
              },
            },
          },
          'Created': variant('created', 'at'),
          'Deleted': variant('deleted', 'reason'),
        },
      },
    };

    test('materializes the sealed switch-delegation shape', () {
      final dtos = generateScaffold(doc).dtos;
      expect(dtos, contains('sealed class Event {'));
      expect(dtos, contains("'created' => Created.fromJson(json)"));
      expect(dtos, contains("'deleted' => Deleted.fromJson(json)"));
      expect(dtos, contains('class Created implements Event {'));
      expect(dtos, contains('class Deleted implements Event {'));
      expect(
        dtos,
        contains('@override'),
      ); // variant toJson overrides the parent
      expect(dtos, contains("throw const BadRequest('unknown Event type')"));
      expect(
        dtos,
        contains("import 'package:keta/keta.dart';"),
      ); // for BadRequest
      // The Schema constant collects the variants transitively.
      expect(dtos, contains("const eventSchema = Schema('Event'"));
      expect(dtos, contains('deps: [createdSchema, deletedSchema]'));
      parseString(content: dtos, throwIfDiagnostics: true); // parses cleanly
    });
  });

  // --- item 1: diagnostic id portability -----------------------------------

  group('diagnostic id portability', () {
    test('the stable id keys on the path WITHIN the enclosing package, so two '
        'checkouts at different absolute locations hash the same file to one id '
        '(the cross-machine portability the id exists for)', () {
      final a = Directory.systemTemp.createTempSync('keta_lints_ida');
      final b = Directory.systemTemp.createTempSync('keta_lints_idb');
      addTearDown(() {
        a.deleteSync(recursive: true);
        b.deleteSync(recursive: true);
      });
      for (final dir in [a, b]) {
        File(
          p.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: fixture\n');
        Directory(p.join(dir.path, 'lib')).createSync();
        File(
          p.join(dir.path, 'lib', 'foo.dart'),
        ).writeAsStringSync('class X {}');
      }
      final relA = packageRelativePath(p.join(a.path, 'lib', 'foo.dart'));
      final relB = packageRelativePath(p.join(b.path, 'lib', 'foo.dart'));
      expect(relA, 'lib/foo.dart');
      expect(relB, 'lib/foo.dart');
      expect(
        diagnosticId(relA, 'X', 'keta_canonical_missing'),
        diagnosticId(relB, 'X', 'keta_canonical_missing'),
      );
    });

    test('a path with no enclosing pubspec falls back to the basename', () {
      final dir = Directory.systemTemp.createTempSync('keta_lints_noroot');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'loose.dart'))
        ..writeAsStringSync('class Y {}');
      // No pubspec.yaml anywhere above the temp file, so the basename is the
      // most stable key available.
      expect(packageRelativePath(file.path), 'loose.dart');
    });
  });

  // --- item 3: syntactic type-drift detection ------------------------------

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
      expect(canonicalDiagnostics(source).any((d) => d.rule == 'keta_type_drift'),
          isFalse);
      expect(applyCanonicalFix(source), source);
    });
  });

  // --- item 5: external-input audit completion -----------------------------

  group('external-input audit — drift', () {
    test('a malformed oracle path item is reported as descriptive drift, not a '
        'raw TypeError that crashes the CI gate', () {
      final drift = contractDrift(
        {
          'paths': {'/x': 'not an operations map'},
        },
        {'paths': <String, Object?>{}},
      );
      expect(drift, isNotEmpty);
      expect(
        drift.map((d) => d.message).join('\n'),
        contains('path "/x" is not an operations mapping'),
      );
      expect(drift.every((d) => d.rule == 'keta_contract_drift'), isTrue);
    });

    test('a malformed oracle schema entry is reported as descriptive drift', () {
      final drift = contractDrift(
        {
          'components': {
            'schemas': {'D': 'not an object'},
          },
        },
        {
          'components': {'schemas': <String, Object?>{}},
        },
      );
      expect(
        drift.map((d) => d.message).join('\n'),
        contains('schema "D" is not an object'),
      );
    });

    test('a non-mapping oracle "paths" is descriptive drift', () {
      final drift = contractDrift({'paths': 'nope'}, {'paths': <String, Object?>{}});
      expect(
        drift.map((d) => d.message).join('\n'),
        contains('"paths" is not a mapping'),
      );
    });
  });

  group('external-input audit — scaffold', () {
    test('a malformed path item raises ScaffoldError instead of a raw '
        'TypeError', () {
      expect(
        () => generateScaffold({
          'paths': {'/x': 'not an operations map'},
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a non-object requestBody raises ScaffoldError', () {
      expect(
        () => generateScaffold({
          'paths': {
            '/x': {
              'post': {
                'requestBody': 'not an object',
                'responses': {'200': <String, Object?>{}},
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a oneOf/discriminator ref to a schema absent from components raises '
        'ScaffoldError instead of emitting Missing.fromJson', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'Event': {
                'oneOf': [
                  {r'$ref': '#/components/schemas/Missing'},
                ],
                'discriminator': {'propertyName': 'type'},
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a required key with no matching property raises ScaffoldError instead '
        'of silently dropping it from the contract-test sample', () {
      expect(
        () => generateScaffold({
          'components': {
            'schemas': {
              'D': {
                'type': 'object',
                'required': ['ghost'],
                'properties': {
                  'id': {'type': 'string'},
                },
              },
            },
          },
        }),
        throwsA(isA<ScaffoldError>()),
      );
    });

    test('a discriminator carrying a \$ still emits a compiling error string '
        '(the sealed BadRequest message goes through dartStringLiteral)', () {
      final doc = {
        'components': {
          'schemas': {
            'Event': {
              'oneOf': [
                {r'$ref': '#/components/schemas/Created'},
              ],
              'discriminator': {
                'propertyName': r'type$',
                'mapping': {'created': '#/components/schemas/Created'},
              },
            },
            'Created': {
              'type': 'object',
              'required': ['at'],
              'properties': {
                'at': {'type': 'string'},
              },
            },
          },
        },
      };
      final dtos = generateScaffold(doc).dtos;
      // The error string is escaped (raw literal), so the generated source
      // compiles rather than treating `$` as interpolation.
      expect(dtos, contains(r"throw const BadRequest(r'unknown Event type$')"));
      parseString(content: dtos, throwIfDiagnostics: true);
    });
  });

  // --- D-1: enhanced-enum wire mapping -------------------------------------

  group('scaffold — enhanced enum (D-1)', () {
    // An enum with a value that is not a valid Dart identifier: kebab-case, a
    // reserved word, and a leading digit all force the enhanced (wire-mapped)
    // form. A plain-identifier value in the same enum keeps its name verbatim.
    Map<String, Object?> docWith(List<Object?> values) => {
      'components': {
        'schemas': {
          'Role': {'type': 'string', 'enum': values},
          'UserDto': {
            'type': 'object',
            'required': ['id', 'role'],
            'properties': {
              'id': {'type': 'string'},
              'role': {r'$ref': '#/components/schemas/Role'},
            },
          },
        },
      },
    };

    test('materializes the enhanced enum, its wire field, and fromWire', () {
      final dtos = generateScaffold(docWith(['admin', 'super-user'])).dtos;
      // The whole file compiles (the `$`-safe derivation, the const ctor, the
      // static factory) — a construction-time guarantee.
      parseString(content: dtos, throwIfDiagnostics: true);
      // fromWire throws BadRequest, so keta is imported.
      expect(dtos, contains("import 'package:keta/keta.dart';"));
      expect(dtos, contains('enum Role {'));
      // A legal value keeps its name; the kebab value is lower-camel-derived and
      // carries its wire string.
      expect(dtos, contains("  admin('admin'),"));
      expect(dtos, contains("  superUser('super-user');"));
      expect(dtos, contains('  const Role(this.wire);'));
      expect(dtos, contains('  final String wire;'));
      expect(dtos, contains('  static Role fromWire(String wire) =>'));
      expect(dtos, contains('v.wire == wire'));
      // fromJson reads via fromWire; toJson writes the wire field.
      expect(dtos, contains("role: Role.fromWire(json['role'] as String),"));
      expect(dtos, contains("'role': role.wire,"));
      // The enum's own Schema constant lists the WIRE strings (so drift is
      // compared against the wire vocabulary, requirement D-1.c).
      expect(dtos, contains("const roleSchema = Schema('Role', "
          "{'type': 'string', 'enum': ['admin', 'super-user']}"));
    });

    test('a reserved word and a leading-digit value derive legal identifiers', () {
      final dtos = generateScaffold(docWith(['default', '2fa'])).dtos;
      parseString(content: dtos, throwIfDiagnostics: true);
      expect(dtos, contains("  default_('default'),"));
      expect(dtos, contains(r"  $2fa('2fa');"));
    });

    test('a plain enum (all values are identifiers) stays byte-identical to the '
        'pre-D-1 form — no wire field, no churn (requirement D-1.a)', () {
      final dtos = generateScaffold(docWith(['admin', 'member'])).dtos;
      expect(dtos, contains('enum Role { admin, member }'));
      expect(dtos, isNot(contains('final String wire')));
      expect(dtos, isNot(contains('fromWire')));
      // The plain form maps name<->wire, so the field mappers use .name/.byName.
      expect(dtos, contains("role: Role.values.byName(json['role'] as String),"));
      expect(dtos, contains("'role': role.name,"));
    });

    test('two wire values that derive one identifier is a ScaffoldError naming '
        'both and the identifier (requirement D-1.b)', () {
      Object? error;
      try {
        generateScaffold(docWith(['super-user', 'super user']));
      } on ScaffoldError catch (e) {
        error = e;
      }
      expect(error, isA<ScaffoldError>());
      final message = (error! as ScaffoldError).message;
      expect(message, contains('super-user'));
      expect(message, contains('super user'));
      expect(message, contains('superUser'));
    });

    test('an enhanced enum as a list item routes through fromWire/.wire', () {
      final doc = {
        'components': {
          'schemas': {
            'Role': {
              'type': 'string',
              'enum': ['super-user', 'admin'],
            },
            'Holder': {
              'type': 'object',
              'required': ['roles'],
              'properties': {
                'roles': {
                  'type': 'array',
                  'items': {r'$ref': '#/components/schemas/Role'},
                },
              },
            },
          },
        },
      };
      final dtos = generateScaffold(doc).dtos;
      parseString(content: dtos, throwIfDiagnostics: true);
      expect(dtos, contains(
          "(json['roles'] as List).map((e) => Role.fromWire(e as String)).toList()"));
      expect(dtos, contains("'roles': roles.map((e) => e.wire).toList(),"));
    });

    test('scaffold -> check -> fix round-trips clean over an enhanced enum: the '
        'materialized DTO is not flagged non-canonical and the fix is a byte-'
        'identical no-op (requirement D-1.c)', () {
      final dtos = generateScaffold(
        docWith(['admin', 'super-user', 'default']),
      ).dtos;
      // check: the enum is not a DTO, and the DTO that uses it round-trips, so
      // nothing is flagged.
      expect(canonicalDiagnostics(dtos), isEmpty);
      // fix: recognizing the enhanced form, there is nothing to reconcile.
      expect(applyCanonicalFix(dtos), dtos);
    });

    test('the generated contract-test sample feeds a wire value fromWire '
        'accepts', () {
      final test = generateScaffold(docWith(['super-user', 'admin'])).contractTest;
      // The sample uses the first enum value verbatim (a wire string), which is
      // exactly what Role.fromWire matches on.
      expect(test, contains("'role': 'super-user'"));
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

  group('contractDrift — enhanced-enum wire strings (D-1)', () {
    test('an emitted enum listing the wire strings agrees with the contract; '
        'listing the derived Dart identifiers instead drifts', () {
      // The value-level enum comparison operates on a property's type signature,
      // so exercise it through an enum-typed property. The point is that the
      // scaffold/fix emit WIRE strings, so a re-emit matches the oracle.
      Map<String, Object?> docWithEnumProp(List<String> values) => {
        'components': {
          'schemas': {
            'Dto': {
              'type': 'object',
              'properties': {
                'role': {'type': 'string', 'enum': values},
              },
            },
          },
        },
      };
      expect(
        contractDrift(
          docWithEnumProp(['admin', 'super-user']),
          docWithEnumProp(['admin', 'super-user']),
        ),
        isEmpty,
      );
      // Had the code listed the Dart identifiers, the enum values would diverge
      // from the contract — the drift the wire-string discipline avoids.
      final drift = contractDrift(
        docWithEnumProp(['admin', 'super-user']),
        docWithEnumProp(['admin', 'superUser']),
      );
      expect(drift.map((d) => d.message).join('\n'), contains('Dto.role'));
    });
  });

  // --- D-2: per-member drift granularity in the fix ------------------------

  group('applyCanonicalFix — per-member granularity (D-2)', () {
    test('a schema-only drift leaves an inline comment inside toJson '
        'byte-for-byte (the mappers are not touched)', () {
      const source = '''
import 'package:keta_openapi/keta_openapi.dart';
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
      expect(fixed, contains("        'id': id,\n"
          '        // keep me\n'
          "        'email': email,"));
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
      expect(fixed, contains('        // keep me\n'
          "        name: json['name'] as String,"));
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
      expect(fixed, contains('        // keep me\n'
          "        'id': id,"));
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
    });
  });
}
