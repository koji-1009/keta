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
          -0.0,
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

      test('accepts finite doubles and ints (jsonEncode-safe)', () {
        for (final value in <num>[
          0,
          1,
          -1,
          3.14,
          -2.5,
          1e308,
          double.maxFinite,
        ]) {
          expect(() => bus.publish('t', value), returnsNormally);
        }
      });

      test('rejects NaN at the top level', () {
        expect(
          () => bus.publish('t', double.nan),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('finite'), contains('message')),
            ),
          ),
        );
      });

      test('rejects +Infinity and -Infinity at the top level', () {
        expect(() => bus.publish('t', double.infinity), throwsArgumentError);
        expect(
          () => bus.publish('t', double.negativeInfinity),
          throwsArgumentError,
        );
      });

      test('rejects a non-finite number nested in a list, naming the path', () {
        expect(
          () => bus.publish('t', <Object?>[1, double.infinity]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('finite'), contains('message[1]')),
            ),
          ),
        );
      });

      test('rejects a non-finite number nested in a map, naming the path', () {
        expect(
          () => bus.publish('t', <String, Object?>{'k': double.nan}),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('finite'), contains('message.k')),
            ),
          ),
        );
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
