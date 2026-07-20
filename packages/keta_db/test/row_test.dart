/// The row accessors' refusals, which no engine is needed to provoke: every
/// one of them is a server-side defect (a wrong column, a wrong storage class,
/// a null where the caller declared none) and therefore a StateError, never a
/// BadRequest.
library;

import 'package:keta/keta.dart' show KetaException;
import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

void main() {
  group('boolAt', () {
    test('reads a native bool and an integer 0/1 alike', () {
      expect({'f': true}.boolAt('f'), isTrue);
      expect({'f': false}.boolAt('f'), isFalse);
      expect({'f': 1}.boolAt('f'), isTrue);
      expect({'f': 0}.boolAt('f'), isFalse);
    });

    test('refuses an integer that is not 0 or 1 — the column was never a '
        'boolean', () {
      expect(() => {'f': 2}.boolAt('f'), throwsStateError);
      expect(() => {'f': 'true'}.boolAt('f'), throwsStateError);
    });

    test('null is an error for the required form, null for the try form', () {
      expect(() => <String, Object?>{'f': null}.boolAt('f'), throwsStateError);
      expect(<String, Object?>{'f': null}.tryBoolAt('f'), isNull);
    });
  });

  group('decimalAt', () {
    test('returns the digits as stored', () {
      expect({'a': '12.10'}.decimalAt('a'), '12.10');
    });

    test('refuses a number, naming the storage class as the cause', () {
      // The digits are already gone by the time this runs; accepting 12.1 here
      // would launder that loss into a value that reads as exact.
      expect(() => {'a': 12.1}.decimalAt('a'), throwsStateError);
      expect(
        () => {'a': 12}.decimalAt('a'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TEXT'),
          ),
        ),
      );
    });
  });

  group('timestampAt', () {
    test('returns the ISO 8601 string unchanged, inventing no offset', () {
      expect(
        {'at': '2026-07-20T09:30:00'}.timestampAt('at'),
        '2026-07-20T09:30:00',
      );
      expect(
        {'at': '2026-07-20T09:30:00Z'}.timestampAt('at'),
        '2026-07-20T09:30:00Z',
      );
    });

    test('refuses a value that is not ISO 8601 — the convention this engine '
        'does not enforce stops here', () {
      expect(() => {'at': '20/07/2026'}.timestampAt('at'), throwsStateError);
      expect(() => {'at': 1784550886}.timestampAt('at'), throwsStateError);
    });
  });

  test('an absent column is an error even through a try accessor, because it '
      'is a defect in the SQL rather than a nullable field', () {
    final row = <String, Object?>{'id': 'a'};
    expect(() => row.tryBoolAt('flag'), throwsStateError);
    expect(
      () => row.tryDecimalAt('amount'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('id')),
      ),
    );
  });

  test(
    'no refusal is a KetaException, so none can be blamed on the client',
    () {
      for (final read in <void Function()>[
        () => {'f': 2}.boolAt('f'),
        () => {'a': 12.1}.decimalAt('a'),
        () => {'at': 'nope'}.timestampAt('at'),
        () => <String, Object?>{}.boolAt('f'),
      ]) {
        expect(read, throwsA(isNot(isA<KetaException>())));
      }
    },
  );

  group('requireCapabilities', () {
    test('passes what the engine has and names what it lacks', () {
      final db = _Caps(
        const DbCapabilities(
          nativeBool: false,
          exactDecimal: false,
          typedTemporal: true,
        ),
      );
      expect(
        () => db.requireCapabilities(typedTemporal: true),
        returnsNormally,
      );
      expect(() => db.requireCapabilities(), returnsNormally);
      expect(
        () => db.requireCapabilities(nativeBool: true, exactDecimal: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('nativeBool'), contains('exactDecimal')),
          ),
        ),
      );
    });

    test('a false requirement is not a requirement', () {
      final db = _Caps(
        const DbCapabilities(
          nativeBool: false,
          exactDecimal: false,
          typedTemporal: false,
        ),
      );
      expect(() => db.requireCapabilities(nativeBool: false), returnsNormally);
    });
  });
}

class _Caps implements Db {
  _Caps(this.capabilities);

  @override
  final DbCapabilities capabilities;

  @override
  DbConn get reader => throw UnimplementedError();

  @override
  DbConn get writer => throw UnimplementedError();

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}
