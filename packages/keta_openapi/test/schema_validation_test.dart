import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

// Sealed-with-discriminator schemas, mirroring the shapes in openapi_test.dart.
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

void main() {
  test('a top-level \$ref absent from deps is a schema-authoring StateError, '
      'not a violation', () {
    // A dangling $ref has nothing to do with the value being checked — it
    // means whoever wrote `Bad`'s `deps` forgot an entry. That is entirely
    // the schema author's mistake (posture (i)), so it must not surface as
    // a violation the client gets blamed for.
    const bad = Schema('Bad', {r'$ref': '#/components/schemas/Missing'});
    expect(
      () => bad.validate({'anything': 1}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('"Bad"'),
            contains(r'$ref'),
            contains('#/components/schemas/Missing'),
          ),
        ),
      ),
    );
  });

  group('type number', () {
    const n = Schema('N', {'type': 'number'});
    test('accepts double and int (int is a num)', () {
      expect(n.validate(3.14), isEmpty);
      expect(n.validate(42), isEmpty);
    });
    test('rejects a non-num', () {
      expect(n.validate('3.14'), [r'$: expected number, got string']);
    });
  });

  group('type integer', () {
    const i = Schema('I', {'type': 'integer'});
    test('a zero-fraction double (1.0) is rejected — a deliberate deviation '
        'from JSON Schema 2020-12', () {
      // JSON Schema 2020-12 admits a zero-fraction number as a valid
      // `integer` instance; this validator does not, on purpose (see the
      // doc comment on the `integer` case in schema.dart): the canonical
      // mapper does `json['x'] as int`, and an admitted `1.0` would crash
      // that cast. Validation and mapping must agree on what "integer"
      // means, so `1.0` — a `double` at runtime, never an `int` — is
      // rejected here exactly as any other non-`int` value would be.
      expect(i.validate(1.0), [r'$: expected integer, got number']);
      expect(i.validate(1), isEmpty);
    });
  });

  group('type boolean', () {
    const b = Schema('B', {'type': 'boolean'});
    test('accepts bool, rejects a string', () {
      expect(b.validate(true), isEmpty);
      expect(b.validate(false), isEmpty);
      expect(b.validate('true'), [r'$: expected boolean, got string']);
    });
  });

  test('a non-Map against an object schema short-circuits', () {
    const o = Schema('O', {
      'type': 'object',
      'required': ['x'],
      'properties': {
        'x': {'type': 'string'},
      },
    });
    // Only the type error — the required check must not also fire.
    expect(o.validate([1, 2]), [r'$: expected object, got array']);
    expect(o.validate('x'), [r'$: expected object, got string']);
  });

  group('array', () {
    test('a non-List is rejected', () {
      const a = Schema('A', {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(a.validate('not-a-list'), [r'$: expected array, got string']);
    });
    test('an array without items validates any element', () {
      const any = Schema('AnyList', {'type': 'array'});
      expect(any.validate([1, 'a', null, <String, Object?>{}]), isEmpty);
      expect(any.validate('x'), isNotEmpty);
    });
  });

  group('oneOf', () {
    test('a non-Map value is rejected', () {
      expect(eventSchema.validate('created'), [
        r'$: expected object, got string',
      ]);
    });
    test(
      'oneOf without a discriminator is a schema-authoring StateError, not a '
      'violation',
      () {
        // Whether `discriminator` is present is fixed by the schema, not by
        // the value being validated — an authoring mistake (posture (i)).
        const s = Schema('NoDisc', {
          'oneOf': [
            {r'$ref': '#/components/schemas/Created'},
          ],
        });
        expect(
          () => s.validate({'type': 'created'}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('"NoDisc"'), contains('discriminator')),
            ),
          ),
        );
      },
    );

    test('a discriminator missing "propertyName" is a StateError naming that '
        'key', () {
      const s = Schema('NoPropName', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Created'},
        ],
        'discriminator': <String, Object?>{},
      });
      expect(
        () => s.validate({'type': 'created'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"NoPropName"'),
              contains('discriminator.propertyName'),
            ),
          ),
        ),
      );
    });

    test('a non-Map discriminator is a StateError, not a TypeError crash', () {
      const s = Schema('BadDisc', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Created'},
        ],
        'discriminator': 'type',
      });
      expect(
        () => s.validate({'type': 'created'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadDisc"'), contains('"discriminator"')),
          ),
        ),
      );
    });

    test('a non-Map discriminator.mapping is a StateError, not a TypeError '
        'crash', () {
      const s = Schema('BadMapping', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Created'},
        ],
        'discriminator': {'propertyName': 'type', 'mapping': 'not-a-map'},
      });
      expect(
        () => s.validate({'type': 'created'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadMapping"'), contains('discriminator.mapping')),
          ),
        ),
      );
    });
    test('a non-string (or missing) discriminator value is rejected', () {
      expect(eventSchema.validate({'type': 42}), [
        r'$.type: discriminator must be a string',
      ]);
      expect(eventSchema.validate(<String, Object?>{}), [
        r'$.type: discriminator must be a string',
      ]);
    });
    test('a mapped ref absent from deps is a schema-authoring StateError, not '
        'an unknown-reference violation', () {
      // The mapping is part of the schema, not the instance: a tag the
      // client sent that has no known variant (tested below, under
      // "unknown discriminator value") stays a violation, but a mapping
      // entry that points at a ref never listed in deps is the author's
      // mistake regardless of what the client sent.
      const dangling = Schema('Dangling', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Ghost'},
        ],
        'discriminator': {
          'propertyName': 'type',
          'mapping': {'ghost': '#/components/schemas/Ghost'},
        },
      });
      expect(
        () => dangling.validate({'type': 'ghost'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"Dangling"'),
              contains('discriminator.mapping'),
              contains('#/components/schemas/Ghost'),
            ),
          ),
        ),
      );
    });

    test('oneOf present but not a list is a schema-authoring StateError', () {
      const s = Schema('BadOneOf', {
        'oneOf': 'not-a-list',
        'discriminator': {'propertyName': 'type'},
      });
      expect(
        () => s.validate({'type': 'created'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadOneOf"'), contains('"oneOf"')),
          ),
        ),
      );
    });
  });

  test(
    'type names in messages cover double/List/Map/null and the fallback',
    () {
      const s = Schema('S', {'type': 'string'});
      expect(s.validate(1.5), [r'$: expected string, got number']);
      expect(s.validate([1]), [r'$: expected string, got array']);
      expect(s.validate({'a': 1}), [r'$: expected string, got object']);
      expect(s.validate(null), [r'$: expected string, got null']);
      expect(s.validate(Duration.zero), [r'$: expected string, got Duration']);
    },
  );

  group('enum on non-string types', () {
    test('an integer enum restricts the value', () {
      const s = Schema('IE', {
        'type': 'integer',
        'enum': [1, 2, 3],
      });
      expect(s.validate(2), isEmpty);
      expect(s.validate(99), [r'$: "99" is not one of 1, 2, 3']);
    });

    test('a type-less enum-only schema still restricts the value', () {
      const s = Schema('EO', {
        'enum': [1, 2, 3],
      });
      expect(s.validate(2), isEmpty);
      expect(s.validate(99), isNotEmpty);
    });

    test(
      'a mixed-member-type enum (still a list) never crashes validation',
      () {
        // A mixed-type enum list is legitimate JSON Schema — members need
        // not share a type — so this is instance-data business (whether the
        // value is a member), never schema-authoring damage.
        const s = Schema('ME', {
          'type': 'string',
          'enum': ['a', 1],
        });
        expect(s.validate('a'), isEmpty);
        expect(s.validate('x'), [r'$: "x" is not one of a, 1']);
      },
    );

    test('"enum" that is not a list at all is a schema-authoring StateError, '
        'not a silent pass', () {
      // Unlike the mixed-type list above, `enum` here isn't a list at
      // all — that can never be legitimate JSON Schema, and the old code
      // silently let anything through in that case (`values is List &&
      // ...` short-circuited false). Silence is exactly the posture the
      // class doc forbids for authoring damage.
      const s = Schema('BadEnum', {'enum': 'not-a-list'});
      expect(
        () => s.validate('anything'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadEnum"'), contains('"enum"')),
          ),
        ),
      );
    });
  });

  group('additionalProperties', () {
    const closed = Schema('Closed', {
      'type': 'object',
      'properties': {
        'a': {'type': 'string'},
      },
      'additionalProperties': false,
    });
    test('false rejects an undeclared key', () {
      expect(
        closed.validate({'a': 'x', 'evil': 1}),
        contains(matches(r'evil: unexpected property')),
      );
    });
    test('false accepts a declared key', () {
      expect(closed.validate({'a': 'x'}), isEmpty);
    });

    test('an absent additionalProperties leaves undeclared keys open', () {
      const open = Schema('Open', {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
      });
      expect(open.validate({'a': 'x', 'anything': 1}), isEmpty);
    });

    test('a value that is neither false nor an object schema (e.g. true) is a '
        'schema-authoring StateError, not a silent pass', () {
      // The old code only handled `== false` and `is Map`; anything
      // else — including the legitimate-looking JSON Schema `true` — fell
      // through both branches and silently imposed no constraint at all.
      // That silence is exactly what the class doc's posture (i) forbids.
      const s = Schema('BadAdditional', {
        'type': 'object',
        'additionalProperties': true,
      });
      expect(
        () => s.validate({'anything': 1}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"BadAdditional"'),
              contains('additionalProperties'),
            ),
          ),
        ),
      );
    });
  });

  group('unknown schema type', () {
    test('a typo\'d type is a schema-authoring StateError, not a violation or '
        'a silent pass', () {
      // Whether `schema['type']` is a recognized name depends only on the
      // schema, never on the value being checked — posture (i), not (ii).
      const s = Schema('Typo', {'type': 'strng'});
      expect(
        () => s.validate('anything'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"Typo"'), contains('strng')),
          ),
        ),
      );
    });

    test('a JSON Schema type array is out of the canonical subset — a '
        'StateError, not a violation', () {
      const s = Schema('TypeArray', {
        'type': ['string', 'null'],
      });
      expect(
        () => s.validate('x'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"TypeArray"'), contains('"type"')),
          ),
        ),
      );
    });

    test('an absent type is not an error (enum-only / oneOf fragments)', () {
      const s = Schema('NoType', {
        'enum': [1, 2],
      });
      expect(s.validate(1), isEmpty);
    });
  });

  group('malformed schema fragments throw a descriptive StateError, never a '
      'violation, TypeError, or silent pass', () {
    test('a non-list "required" names the schema and "required"', () {
      const s = Schema('BadRequired', {
        'type': 'object',
        'required': 'id',
        'properties': {
          'id': {'type': 'string'},
        },
      });
      expect(
        () => s.validate({'id': 'x'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"BadRequired"'),
              contains('"required" must be a list of strings'),
            ),
          ),
        ),
      );
    });

    test('a "required" list with a non-string entry is caught too, not '
        'silently dropped', () {
      // The old code used `.whereType<String>()`, which would have
      // silently dropped the bad entry and validated as if it were never
      // there — a silent pass on authoring damage.
      const s = Schema('BadRequiredEntry', {
        'type': 'object',
        'required': ['id', 42],
        'properties': {
          'id': {'type': 'string'},
        },
      });
      expect(
        () => s.validate({'id': 'x'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadRequiredEntry"'), contains('"required"')),
          ),
        ),
      );
    });

    test('a non-map "properties" names the schema and "properties"', () {
      const s = Schema('BadProperties', {
        'type': 'object',
        'properties': 'not-a-map',
      });
      expect(
        () => s.validate({'x': 1}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadProperties"'), contains('"properties"')),
          ),
        ),
      );
    });

    test('a non-map property sub-schema names the schema and the property', () {
      const s = Schema('BadProperty', {
        'type': 'object',
        'properties': {'x': 'not-a-schema'},
      });
      expect(
        () => s.validate({'x': 1}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadProperty"'), contains('properties.x')),
          ),
        ),
      );
    });

    test('a non-map "items" names the schema and "items"', () {
      const s = Schema('BadItems', {'type': 'array', 'items': 'nope'});
      expect(
        () => s.validate([1, 2]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadItems"'), contains('"items"')),
          ),
        ),
      );
    });

    test('a "\$ref" that is not a string names the schema and "\$ref"', () {
      const s = Schema('BadRef', {r'$ref': 42});
      expect(
        () => s.validate({'x': 1}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"BadRef"'), contains(r'$ref')),
          ),
        ),
      );
    });
  });

  group('oneOf implicit mapping', () {
    const cat = Schema('Cat', {
      'type': 'object',
      'required': ['kind', 'meow'],
      'properties': {
        'kind': {'type': 'string'},
        'meow': {'type': 'boolean'},
      },
    });
    const dog = Schema('Dog', {
      'type': 'object',
      'required': ['kind', 'bark'],
      'properties': {
        'kind': {'type': 'string'},
        'bark': {'type': 'boolean'},
      },
    });
    // No explicit mapping: the discriminator value maps to the schema by name.
    const pet = Schema(
      'Pet',
      {
        'oneOf': [
          {r'$ref': '#/components/schemas/Cat'},
          {r'$ref': '#/components/schemas/Dog'},
        ],
        'discriminator': {'propertyName': 'kind'},
      },
      deps: [cat, dog],
    );

    test('resolves the variant by schema name when no mapping is given', () {
      expect(pet.validate({'kind': 'Cat', 'meow': true}), isEmpty);
      expect(pet.validate({'kind': 'Dog', 'bark': false}), isEmpty);
      expect(
        pet.validate({'kind': 'Cat'}),
        contains(matches(r'meow: required')),
      );
    });

    test(
      'an unknown discriminator value is a violation, not a schema-authoring '
      'StateError',
      () {
        // Unlike an explicit mapping's dangling ref (tested above), the ref
        // here is built straight from the client's own "kind" — whether it
        // resolves depends entirely on what the client sent, so a miss is
        // instance-data business, the same posture as an unrecognized enum
        // value, and must not become a StateError.
        expect(
          pet.validate({'kind': 'Fish'}),
          contains(matches(r'"Fish" has no variant')),
        );
      },
    );
  });

  group('Schema.requireMap', () {
    const user = Schema('ReqMapUser', {
      'type': 'object',
      'required': ['id'],
      'properties': {
        'id': {'type': 'string'},
      },
    });

    test('a valid object comes back typed as Map<String, Object?>', () {
      final Map<String, Object?> result = user.requireMap({'id': 'a'});
      expect(result, {'id': 'a'});
    });

    test('invalid instance data is still a BadRequest(400)', () {
      expect(
        () => user.requireMap(<String, Object?>{}),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
    });

    test(
      'a validated-but-non-map value is a BadRequest, never a TypeError',
      () {
        // Nothing in `AnyValue` restricts the instance to an object, so a
        // list validates cleanly and yet is not a map — requireMap must
        // narrow that itself rather than let `as Map<String, Object?>` crash
        // at the call site.
        const anyValue = Schema('AnyValue', {});
        expect(
          () => anyValue.requireMap([1, 2, 3]),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
        );
      },
    );
  });
}
