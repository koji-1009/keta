/// `listSchema`'s canonical `{items, total}` envelope: the emitted document
/// shape (items array + required total + the closed `additionalProperties`
/// posture), `validate` acceptance of a conforming envelope, rejection with
/// correct instance paths for a missing `total` and a malformed item, and
/// composition with a realistic (multi-property) item schema.
library;

import 'package:keta/keta.dart';
import 'package:test/test.dart';

const _itemSchema = Schema('Item', {
  'type': 'object',
  'required': ['id', 'name'],
  'properties': {
    'id': {'type': 'string'},
    'name': {'type': 'string'},
  },
});

void main() {
  final schema = listSchema(_itemSchema);

  group('emitted document shape', () {
    test('the wrapper is named after the item schema', () {
      expect(schema.name, 'ItemList');
    });

    test('items and total are both required', () {
      expect(schema.json['required'], ['items', 'total']);
    });

    test('items is an array whose elements ref the item schema', () {
      final properties = schema.json['properties'] as Map<String, Object?>;
      expect(properties['items'], {
        'type': 'array',
        'items': {r'$ref': '#/components/schemas/Item'},
      });
    });

    test('total is a bare integer', () {
      final properties = schema.json['properties'] as Map<String, Object?>;
      expect(properties['total'], {'type': 'integer'});
    });

    test('additionalProperties is false — the envelope is closed', () {
      expect(schema.json['additionalProperties'], false);
    });

    test('the item schema is carried in deps so the walker collects it', () {
      expect(schema.deps, [_itemSchema]);
    });
  });

  group('validate — acceptance', () {
    test('a conforming envelope has no violations', () {
      expect(
        schema.validate({
          'items': [
            {'id': '1', 'name': 'a'},
            {'id': '2', 'name': 'b'},
          ],
          'total': 2,
        }),
        isEmpty,
      );
    });

    test('an empty page with a nonzero total is valid', () {
      // The honest answer to an offset past the end of the result set: an
      // empty `items` with the real `total`, not a violation.
      expect(schema.validate({'items': <Object?>[], 'total': 5}), isEmpty);
    });
  });

  group('validate — rejection', () {
    test('a missing total is a violation at the envelope path', () {
      expect(schema.validate({'items': <Object?>[]}), [
        r'$.total: required property is missing',
      ]);
    });

    test('a missing items is a violation at the envelope path', () {
      expect(schema.validate({'total': 0}), [
        r'$.items: required property is missing',
      ]);
    });

    test('a wrong item shape is a violation at its array index', () {
      expect(
        schema.validate({
          'items': [
            {'id': '1'}, // missing 'name'
          ],
          'total': 1,
        }),
        [r'$.items[0].name: required property is missing'],
      );
    });

    test('a non-array items is a type violation, not a crash', () {
      expect(schema.validate({'items': 'nope', 'total': 0}), [
        r'$.items: expected array, got string',
      ]);
    });

    test('an unexpected top-level property is rejected (closed envelope)', () {
      expect(schema.validate({'items': <Object?>[], 'total': 0, 'page': 1}), [
        r'$.page: unexpected property (additionalProperties is false)',
      ]);
    });
  });

  group('composition with a realistic item schema', () {
    // A nested-DTO item schema (a $ref of its own) exercises the two-level
    // ref chain: the envelope refs Item, and — realistically — an item
    // schema often refs something else in turn.
    const tagSchema = Schema('Tag', {
      'type': 'object',
      'required': ['label'],
      'properties': {
        'label': {'type': 'string'},
      },
    });
    const taggedItemSchema = Schema(
      'TaggedItem',
      {
        'type': 'object',
        'required': ['id', 'tag'],
        'properties': {
          'id': {'type': 'string'},
          'tag': {r'$ref': '#/components/schemas/Tag'},
        },
      },
      deps: [tagSchema],
    );
    final taggedListSchema = listSchema(taggedItemSchema);

    test('deps carries the item schema, which carries its own deps', () {
      expect(taggedListSchema.deps, [taggedItemSchema]);
      expect(taggedListSchema.deps.single.deps, [tagSchema]);
    });

    test(r'validate resolves the nested $ref through the item schema', () {
      expect(
        taggedListSchema.validate({
          'items': [
            {
              'id': '1',
              'tag': {'label': 'x'},
            },
          ],
          'total': 1,
        }),
        isEmpty,
      );
    });

    test('a violation inside the nested ref reports the full path', () {
      expect(
        taggedListSchema.validate({
          'items': [
            {'id': '1', 'tag': <String, Object?>{}},
          ],
          'total': 1,
        }),
        [r'$.items[0].tag.label: required property is missing'],
      );
    });
  });
}
