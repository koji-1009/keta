/// Pins the message contract: a message must be a canonical JSON value
/// (null/bool/num/String/List/`Map<String, Object?>`), the shape that survives an
/// isolate boundary. A non-JSON value is rejected at publish with a descriptive
/// ArgumentError that names the offending path — enforced identically by every
/// implementation, so InMemoryBus is a faithful stand-in for IsolateBus.
library;

import 'package:keta_bus/keta_bus.dart';
import 'package:test/test.dart';

class _NotJson {
  const _NotJson();
}

void main() {
  for (final entry in <String, Bus Function()>{
    'InMemoryBus': InMemoryBus.new,
    'IsolateBus.hub': IsolateBus.hub,
  }.entries) {
    group(entry.key, () {
      late Bus bus;
      setUp(() => bus = entry.value());
      tearDown(() => bus.close());

      test('accepts the canonical JSON scalars and containers', () {
        for (final value in <Object?>[
          null,
          true,
          42,
          3.14,
          'text',
          <Object?>[1, 'two', null],
          <String, Object?>{
            'a': 1,
            'b': <Object?>[2, 3],
          },
        ]) {
          expect(() => bus.publish('t', value), returnsNormally);
        }
      });

      test('rejects a non-JSON leaf', () {
        expect(() => bus.publish('t', const _NotJson()), throwsArgumentError);
      });

      test('rejects a non-JSON value nested in a list', () {
        expect(
          () => bus.publish('t', <Object?>[1, const _NotJson()]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('message[1]'),
            ),
          ),
        );
      });

      test('rejects a non-String map key', () {
        expect(
          () => bus.publish('t', <Object?, Object?>{1: 'v'}),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('keys must be String'),
            ),
          ),
        );
      });

      test('rejects a non-JSON value nested in a map', () {
        expect(
          () => bus.publish('t', <String, Object?>{'k': const _NotJson()}),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('message.k'),
            ),
          ),
        );
      });
    });
  }
}
