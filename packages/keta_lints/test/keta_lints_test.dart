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

    test('a DTO without mappers is keta_canonical_missing', () {
      const source = '''
class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
}
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
class UserDto {
  final String id;
  final int? age;
  UserDto({required this.id, this.age});
}
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
