/// Fixtures shared verbatim across the split `keta_lints` test files, kept
/// here so the byte-identical source each file asserts against cannot
/// silently drift apart between them.
library;

/// A small but representative OpenAPI oracle: a GET with a path capture, a
/// POST whose success is 201 (not 200), a plain enum, and a DTO with a
/// required nested-enum field plus an optional scalar and a string array.
///
/// Used by scaffold_test.dart (as the document to materialize) and by
/// drift_test.dart (as the oracle side of a diff).
Map<String, Object?> get sampleOracle => {
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

/// A DTO whose `fromJson` still reads the pre-rename wire key (`id`) while
/// every other axis (the field name, `toJson`) already agrees on `uuid` — the
/// minimal repro for a stale-key-only drift with no accompanying key/type
/// drift on the other mapper.
///
/// Shared between canonical_check_test.dart (the message-content pin) and
/// canonical_fix_test.dart (the repair + idempotence pin).
const staleFromJsonKeyOnly = '''
class Dto {
  final String uuid;
  Dto({required this.uuid});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(uuid: json['id'] as String);
  Map<String, Object?> toJson() => {'uuid': uuid};
}
''';

/// A DTO whose `toJson` delegates to a private helper (`_custom()`) instead of
/// a literal map. The canonical shape is only recognized from a literal, so
/// this is unrecognized on both sides: the checker stays silent (it isn't
/// verified) and the fixer refuses to touch it (ditto).
///
/// Shared between canonical_check_test.dart and canonical_fix_test.dart,
/// which each pin one half of that contract.
const handModifiedToJsonCustom = '''
class Weird {
  final String id;
  Weird(this.id);
  factory Weird.fromJson(Map<String, Object?> json) => Weird(json['id'] as String);
  Map<String, Object?> toJson() => _custom();
  Map<String, Object?> _custom() => {'id': id};
}
''';
