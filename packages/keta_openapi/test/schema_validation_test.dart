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
  test('a top-level \$ref absent from deps is an unknown reference', () {
    const bad = Schema('Bad', {r'$ref': '#/components/schemas/Missing'});
    expect(bad.validate({'anything': 1}), [
      r'$: unknown schema reference "#/components/schemas/Missing"',
    ]);
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
    test('oneOf without a discriminator is unsupported', () {
      const s = Schema('NoDisc', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Created'},
        ],
      });
      expect(s.validate({'type': 'created'}), [
        r'$: oneOf without a discriminator is not supported',
      ]);
    });
    test('a non-string (or missing) discriminator value is rejected', () {
      expect(eventSchema.validate({'type': 42}), [
        r'$.type: discriminator must be a string',
      ]);
      expect(eventSchema.validate(<String, Object?>{}), [
        r'$.type: discriminator must be a string',
      ]);
    });
    test('a mapped ref absent from deps is an unknown reference', () {
      const dangling = Schema('Dangling', {
        'oneOf': [
          {r'$ref': '#/components/schemas/Ghost'},
        ],
        'discriminator': {
          'propertyName': 'type',
          'mapping': {'ghost': '#/components/schemas/Ghost'},
        },
      });
      expect(dangling.validate({'type': 'ghost'}), [
        r'$: unknown schema reference "#/components/schemas/Ghost"',
      ]);
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

    test('a malformed enum (mixed member types) never crashes validation', () {
      const s = Schema('ME', {
        'type': 'string',
        'enum': ['a', 1],
      });
      expect(s.validate('a'), isEmpty);
      expect(s.validate('x'), [r'$: "x" is not one of a, 1']);
    });
  });

  group('additionalProperties: false', () {
    const closed = Schema('Closed', {
      'type': 'object',
      'properties': {
        'a': {'type': 'string'},
      },
      'additionalProperties': false,
    });
    test('rejects an undeclared key', () {
      expect(
        closed.validate({'a': 'x', 'evil': 1}),
        contains(matches(r'evil: unexpected property')),
      );
    });
    test('accepts a declared key', () {
      expect(closed.validate({'a': 'x'}), isEmpty);
    });
  });

  group('unknown schema type', () {
    test('a typo\'d type is a validation error, not a silent pass', () {
      const s = Schema('Typo', {'type': 'strng'});
      expect(s.validate('anything'), [r"$: unknown schema type 'strng'"]);
      expect(s.validate(42), [r"$: unknown schema type 'strng'"]);
    });

    test('a JSON Schema type array is out of the canonical subset', () {
      const s = Schema('TypeArray', {
        'type': ['string', 'null'],
      });
      expect(s.validate('x'), contains(matches(r'unknown schema type')));
    });

    test('an absent type is not an error (enum-only / oneOf fragments)', () {
      const s = Schema('NoType', {
        'enum': [1, 2],
      });
      expect(s.validate(1), isEmpty);
    });
  });

  group('malformed schema fragments do not crash validation', () {
    test('a non-list "required" is a violation, not a cast crash', () {
      const s = Schema('BadRequired', {
        'type': 'object',
        'required': 'id',
        'properties': {
          'id': {'type': 'string'},
        },
      });
      expect(
        s.validate({'id': 'x'}),
        contains(matches(r'"required" must be a list of strings')),
      );
    });

    test('a non-map property sub-schema is a violation, not a cast crash', () {
      const s = Schema('BadProperty', {
        'type': 'object',
        'properties': {'x': 'not-a-schema'},
      });
      expect(
        s.validate({'x': 1}),
        contains(matches(r'x: schema fragment must be an object')),
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

    test('an unknown discriminator value is an unknown reference', () {
      expect(
        pet.validate({'kind': 'Fish'}),
        contains(matches(r'unknown schema reference')),
      );
    });
  });
}
