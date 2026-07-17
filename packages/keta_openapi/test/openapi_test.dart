import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

// The §4 canonical shape, hand-written. keta_lints must recognize and
// materialize exactly this; here we prove it works by hand.

enum Role { admin, member }

class UserDto {
  UserDto({
    required this.id,
    required this.name,
    this.age,
    required this.role,
    required this.tags,
  });

  factory UserDto.fromJson(Map<String, Object?> json) => UserDto(
    id: json['id'] as String,
    name: json['name'] as String,
    age: json['age'] as int?,
    role: Role.values.byName(json['role'] as String),
    tags: (json['tags'] as List).cast<String>(),
  );
  final String id;
  final String name;
  final int? age;
  final Role role;
  final List<String> tags;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (age != null) 'age': age,
    'role': role.name,
    'tags': tags,
  };
}

const userDtoSchema = Schema('UserDto', {
  'type': 'object',
  'required': ['id', 'name', 'role', 'tags'],
  'properties': {
    'id': {'type': 'string'},
    'name': {'type': 'string'},
    'age': {'type': 'integer'},
    'role': {
      'type': 'string',
      'enum': ['admin', 'member'],
    },
    'tags': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
});

// Sealed with a discriminator.

const createdSchema = Schema('Created', {
  'type': 'object',
  'required': ['type', 'at'],
  'properties': {
    'type': {'type': 'string'},
    'at': {'type': 'string'},
  },
});
const deletedSchema = Schema('Deleted', {
  'type': 'object',
  'required': ['type', 'reason'],
  'properties': {
    'type': {'type': 'string'},
    'reason': {'type': 'string'},
  },
});
const eventSchema = Schema(
  'Event',
  {
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
  deps: [createdSchema, deletedSchema],
);

class Ignored {}

void main() {
  group('canonical DTO round-trip', () {
    test('fromJson(toJson(x)) preserves the value', () {
      final user = UserDto(
        id: '1',
        name: 'Ada',
        role: Role.admin,
        tags: ['x', 'y'],
      );
      final back = UserDto.fromJson(user.toJson());
      expect(back.id, '1');
      expect(back.age, isNull);
      expect(back.role, Role.admin);
      expect(back.tags, ['x', 'y']);
    });
  });

  group('Schema.validate', () {
    test('accepts a valid object and passes toJson output', () {
      final user = UserDto(
        id: '1',
        name: 'Ada',
        role: Role.member,
        tags: ['a'],
      );
      expect(userDtoSchema.validate(user.toJson()), isEmpty);
    });

    test('reports missing required, wrong type, and bad enum', () {
      final errors = userDtoSchema.validate({
        'id': 'x',
        'age': 'not-an-int',
        'role': 'root',
        'tags': ['ok', 1],
      });
      expect(errors, contains(matches(r'name: required')));
      expect(errors, contains(matches(r'age: expected integer')));
      expect(errors, contains(matches(r'role: "root" is not one of')));
      expect(errors, contains(matches(r'tags\[1\]: expected string')));
    });

    test('require returns the value or throws KetaException(400)', () {
      final ok = userDtoSchema.require({
        'id': 'a',
        'name': 'b',
        'role': 'admin',
        'tags': <String>[],
      });
      expect((ok as Map)['id'], 'a');
      expect(
        () => userDtoSchema.require({'id': 'a'}),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
    });

    test('accepts an explicit null for an optional field', () {
      expect(
        userDtoSchema.validate({
          'id': 'a',
          'name': 'b',
          'age': null,
          'role': 'admin',
          'tags': <String>[],
        }),
        isEmpty,
      );
    });

    test('validates Map<String,T> via additionalProperties', () {
      const counts = Schema('Counts', {
        'type': 'object',
        'additionalProperties': {'type': 'integer'},
      });
      expect(counts.validate({'a': 1, 'b': 2}), isEmpty);
      expect(
        counts.validate({'a': 1, 'b': 'x'}),
        contains(matches(r'b: expected integer')),
      );
    });
  });

  group('sealed schema', () {
    test('validates the variant selected by the discriminator', () {
      expect(eventSchema.validate({'type': 'created', 'at': 'now'}), isEmpty);
      expect(
        eventSchema.validate({'type': 'deleted', 'reason': 'gone'}),
        isEmpty,
      );
      expect(
        eventSchema.validate({'type': 'created'}),
        contains(matches(r'at: required')),
      );
      expect(
        eventSchema.validate({'type': 'unknown'}),
        contains(matches(r'has no variant')),
      );
    });
  });

  group('OpenApi.fromRoutes', () {
    App<Ignored> buildApp() {
      final app = App<Ignored>();
      app.get(
        '/users/:id',
        (c) => c.text('x'),
        doc: const RouteDoc(
          success: Success(schema: userDtoSchema),
          summary: 'get user',
        ),
      );
      app
          .on(root.segments('users'))
          .post(
            (c, _) => c.text('x'),
            doc: const RouteDoc(
              success: Success(schema: userDtoSchema),
              requestBody: userDtoSchema,
            ),
          );
      return app;
    }

    test('extracts paths, parameters, and components', () {
      final spec = OpenApi.fromRoutes(
        buildApp().routes,
        title: 'Users',
        version: '1.0',
      );
      final doc = spec.toJson();

      expect(doc['openapi'], '3.1.0');
      expect((doc['info'] as Map)['title'], 'Users');

      final paths = doc['paths'] as Map;
      expect(paths.keys, containsAll(['/users/{id}', '/users']));

      final getOp = (paths['/users/{id}'] as Map)['get'] as Map;
      expect(getOp['summary'], 'get user');
      final param = (getOp['parameters'] as List).single as Map;
      expect(param['name'], 'id');
      expect(param['in'], 'path');
      expect((param['schema'] as Map)['type'], 'string');
      final ok = (getOp['responses'] as Map)['200'] as Map;
      final schemaRef =
          (((ok['content'] as Map)['application/json'] as Map)['schema']
              as Map)[r'$ref'];
      expect(schemaRef, '#/components/schemas/UserDto');

      final postOp = (paths['/users'] as Map)['post'] as Map;
      expect((postOp['requestBody'] as Map)['required'], true);

      final schemas = (doc['components'] as Map)['schemas'] as Map;
      expect(schemas.keys, contains('UserDto'));
    });

    test('the declared success is the one that reaches the document', () {
      // The status is declared, not guessed from an absence. The guess was 200
      // whenever a route said nothing, and POST /users answers 201 — so it was
      // documented as a 200 it never returns. Nothing fabricates a 200 beside
      // this 201, because there is no fabrication left.
      final app = App<Ignored>();
      app
          .on(root.segments('users'))
          .post(
            (c, _) => c.text('x', status: 201),
            doc: const RouteDoc(success: Success(status: 201)),
          );
      final op =
          ((OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map)['/users']
                  as Map)['post']
              as Map;
      expect((op['responses'] as Map).keys, ['201']);
    });

    test('a declared failure sits beside the success, not over it', () {
      // The emitter used to skip the 200 whenever any response was declared, so
      // /admin/ping — which declares only its 403 — carried no 2xx while its
      // handler returned 'pong'. `success` being required is what makes that
      // unwritable now; this holds the two apart.
      final app = App<Ignored>();
      app
          .on(root.segments('ping'))
          .get(
            (c, _) => c.text('pong'),
            doc: const RouteDoc(
              success: Success(),
              failureResponses: {403: userDtoSchema},
            ),
          );
      final op =
          ((OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map)['/ping']
                  as Map)['get']
              as Map;
      final responses = op['responses'] as Map;
      expect(responses.containsKey('200'), isTrue, reason: 'the happy path');
      expect(responses.containsKey('403'), isTrue, reason: "the user's own");
    });

    test('a success in failureResponses is rejected, naming the route', () {
      // `Map<int, Schema>` cannot exclude 2xx, so the field name carries the
      // rule and this holds callers to it — a route has exactly one success,
      // and it lives in `success`. (A `const Success(status: 500)` needs no
      // test here: the assert makes it a compile error. A non-const one is
      // covered below, where the assert can't run at all.)
      final app = App<Ignored>();
      app
          .on(root.segments('users'))
          .post(
            (c, _) => c.text('x', status: 201),
            doc: const RouteDoc(
              success: Success(),
              failureResponses: {201: userDtoSchema},
            ),
          );
      expect(
        () => OpenApi.fromRoutes(app.routes),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('POST /users'), contains('201')),
          ),
        ),
      );
    });

    test('a non-const Success.status outside 2xx/3xx is a hard error at emit '
        'time, not merely the constructor\'s assert', () async {
      // `Success(status: 500)` trips the constructor's `assert` under
      // `dart test`, which enables assertions — the assert would fire
      // before OpenApi.fromRoutes is ever reached, so this in-process test
      // cannot construct the bad value directly. A release binary (`dart
      // run`, `dart compile exe`) runs with assertions off by default,
      // which is exactly the scenario the emit-time guard exists for; a
      // subprocess run that way is the only way to actually exercise it.
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/support/bad_success_release_mode.dart',
      ]);
      expect(
        result.exitCode,
        isNot(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      // An uncaught StateError prints as `Bad state: <message>` (its own
      // `toString`), not the class name — assert on the message it carries.
      expect(
        result.stderr,
        allOf(contains('Bad state:'), contains('not a 2xx/3xx')),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
    });

    test('toYaml emits a document that parses back to the same structure', () {
      final spec = OpenApi.fromRoutes(buildApp().routes);
      final parsed = loadYaml(spec.toYaml());
      final normalized = _plain(parsed);
      expect(normalized, spec.toJson());
    });
  });
}

/// Converts YamlMap/YamlList into plain Dart maps/lists for comparison.
Object? _plain(Object? node) => switch (node) {
  YamlMap() => {
    for (final entry in node.nodes.entries)
      (entry.key as YamlScalar).value.toString(): _plain(entry.value),
  },
  YamlList() => [for (final item in node.nodes) _plain(item)],
  YamlScalar() => node.value,
  _ => node,
};
