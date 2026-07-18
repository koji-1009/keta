/// `contractDrift` — diffing an oracle OpenAPI document against a
/// code-derived shadow document: endpoints, schemas, fields, required-ness,
/// types, and enum wire vocabularies present on only one side, plus
/// malformed-oracle robustness (descriptive drift over a raw TypeError).
library;

import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('contractDrift', () {
    test('reports endpoints and fields present only on one side', () {
      final oracle = sampleOracle;
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
      expect(contractDrift(sampleOracle, sampleOracle), isEmpty);
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

  group('contractDrift — type and required-ness changes', () {
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
  });

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

    test(
      'a malformed oracle schema entry is reported as descriptive drift',
      () {
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
      },
    );

    test('a non-mapping oracle "paths" is descriptive drift', () {
      final drift = contractDrift(
        {'paths': 'nope'},
        {'paths': <String, Object?>{}},
      );
      expect(
        drift.map((d) => d.message).join('\n'),
        contains('"paths" is not a mapping'),
      );
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
}
