/// `generateScaffold` — materializing DTOs, route skeletons, and contract
/// tests from an OpenAPI oracle, including the enhanced-enum wire mapping,
/// sealed-variant delegation, and malformed-oracle robustness (ScaffoldError
/// over a raw TypeError).
library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('scaffold', () {
    final scaffold = generateScaffold(sampleOracle);

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
        ...sampleOracle,
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
          ...sampleOracle,
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

  group('scaffold — malformed input produces ScaffoldError, not a raw crash', () {
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
  });

  group('scaffold — query', () {
    test('a query parameter flows into the route doc and a 400 test', () {
      final doc = {
        ...sampleOracle,
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

    test(
      'a required key with no matching property raises ScaffoldError instead '
      'of silently dropping it from the contract-test sample',
      () {
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
      },
    );

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
      expect(
        dtos,
        contains(
          "const roleSchema = Schema('Role', "
          "{'type': 'string', 'enum': ['admin', 'super-user']}",
        ),
      );
    });

    test(
      'a reserved word and a leading-digit value derive legal identifiers',
      () {
        final dtos = generateScaffold(docWith(['default', '2fa'])).dtos;
        parseString(content: dtos, throwIfDiagnostics: true);
        expect(dtos, contains("  default_('default'),"));
        expect(dtos, contains(r"  $2fa('2fa');"));
      },
    );

    test('a plain enum (all values are identifiers) stays byte-identical to the '
        'pre-D-1 form — no wire field, no churn (requirement D-1.a)', () {
      final dtos = generateScaffold(docWith(['admin', 'member'])).dtos;
      expect(dtos, contains('enum Role { admin, member }'));
      expect(dtos, isNot(contains('final String wire')));
      expect(dtos, isNot(contains('fromWire')));
      // The plain form maps name<->wire, so the field mappers use .name/.byName.
      expect(
        dtos,
        contains("role: Role.values.byName(json['role'] as String),"),
      );
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
      expect(
        dtos,
        contains(
          "(json['roles'] as List).map((e) => Role.fromWire(e as String)).toList()",
        ),
      );
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
      final test = generateScaffold(
        docWith(['super-user', 'admin']),
      ).contractTest;
      // The sample uses the first enum value verbatim (a wire string), which is
      // exactly what Role.fromWire matches on.
      expect(test, contains("'role': 'super-user'"));
    });
  });
}
