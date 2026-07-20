/// keta_db's test-support library: the conformance suite every [Db] adapter
/// runs against a live engine.
///
/// A separate import alongside `package:keta_db/keta_db.dart`, following
/// `package:keta/test.dart` — test-only support ships with the package it
/// tests, rather than in a package of its own that would need its own release.
library;

import 'package:keta/keta.dart';
import 'package:test/test.dart';

import 'keta_db.dart';

/// Runs the behaviour every [Db] adapter owes its callers, against a live
/// engine, so the floor is written once instead of once per adapter.
///
/// Before this existed keta_sqlite and keta_rds each wrote their own
/// expectations, and the gaps were invisible: the SQLite suite had no boolean
/// test at all, because nobody looking only at SQLite would think to add one.
/// A shared floor makes an omission structural rather than a matter of who
/// remembered what.
///
/// **Expectations switch on `db.capabilities`, never on the engine's name.**
/// That is what keeps the suite honest about the differences instead of
/// papering over them: where an engine cannot do something, the suite asserts
/// that it *demonstrably* cannot, so a capability that is declared wrongly
/// fails here rather than in production.
///
/// The DDL types are the caller's because SQL dialect is deliberately outside
/// keta's scope — the migration runner hands your `.sql` to the engine
/// untouched, and this suite is no different. Pass what the engine spells:
/// `boolType: 'boolean'` / `'integer'`, `decimalType: 'numeric(12,2)'` /
/// `'text'`, `timestampType: 'timestamptz'` / `'text'`.
void runDbConformance({
  required Future<Db> Function() open,
  required String boolType,
  required String decimalType,
  required String timestampType,
}) {
  group('DbConn conformance', () {
    late Db db;

    setUp(() async {
      db = await open();
      await db.writer.execute('drop table if exists keta_conformance');
      await db.writer.execute('''
create table keta_conformance (
  id text primary key,
  flag $boolType,
  amount $decimalType,
  at $timestampType
)
''');
    });

    tearDown(() async {
      await db.writer.execute('drop table if exists keta_conformance');
      await db.close();
    });

    Future<Map<String, Object?>> insertAndRead({
      required String id,
      required Object? flag,
      required Object? amount,
      required Object? at,
    }) async {
      await db.writer.execute(
        'insert into keta_conformance (id, flag, amount, at) '
        'values (?, ?, ?, ?)',
        [id, flag, amount, at],
      );
      final rows = await db.reader.query(
        'select id, flag, amount, at from keta_conformance where id = ?',
        [id],
      );
      return rows.single;
    }

    test('rows come back as column-name maps', () async {
      final row = await insertAndRead(
        id: 'a',
        flag: null,
        amount: null,
        at: null,
      );
      expect(row.keys, containsAll(['id', 'flag', 'amount', 'at']));
      expect(row['id'], 'a');
    });

    test('execute reports the rows it changed', () async {
      await insertAndRead(id: 'a', flag: null, amount: null, at: null);
      final changed = await db.writer.execute(
        "update keta_conformance set id = 'b' where id = ?",
        ['a'],
      );
      expect(changed, 1);
    });

    test('a uniqueness violation is a Conflict — the floor every adapter '
        'owes, whatever the engine calls it', () async {
      await insertAndRead(id: 'a', flag: null, amount: null, at: null);
      await expectLater(
        db.writer.execute('insert into keta_conformance (id) values (?)', [
          'a',
        ]),
        throwsA(isA<Conflict>()),
      );
    });

    test('a boolean reads as a Dart bool through boolAt on every engine, '
        'whatever the storage class', () async {
      final caps = db.capabilities;
      final trueRow = await insertAndRead(
        id: 'a',
        flag: caps.nativeBool ? true : 1,
        amount: null,
        at: null,
      );
      final falseRow = await insertAndRead(
        id: 'b',
        flag: caps.nativeBool ? false : 0,
        amount: null,
        at: null,
      );
      expect(trueRow.boolAt('flag'), isTrue);
      expect(falseRow.boolAt('flag'), isFalse);
      expect(trueRow.tryBoolAt('flag'), isTrue);

      // The capability is a claim about the RAW value, and this is where a
      // wrong claim fails.
      expect(
        trueRow['flag'],
        caps.nativeBool ? isA<bool>() : isA<int>(),
        reason: 'capabilities.nativeBool is ${caps.nativeBool}',
      );
    });

    test('a NULL boolean is null through tryBoolAt and an error through '
        'boolAt', () async {
      final row = await insertAndRead(
        id: 'a',
        flag: null,
        amount: null,
        at: null,
      );
      expect(row.tryBoolAt('flag'), isNull);
      expect(() => row.boolAt('flag'), throwsStateError);
    });

    test('a decimal round-trips exactly through decimalAt, in the column type '
        'this engine requires for exactness', () async {
      final row = await insertAndRead(
        id: 'a',
        flag: null,
        amount: '12.10',
        at: null,
      );
      expect(row.decimalAt('amount'), '12.10');
      expect(row.tryDecimalAt('amount'), '12.10');
    });

    test('an engine without exact-decimal storage demonstrably loses digits '
        'in a NUMERIC column, and decimalAt refuses the result', () async {
      if (db.capabilities.exactDecimal) return;
      await db.writer.execute(
        'create table keta_conformance_lossy (id text primary key, '
        'amount numeric)',
      );
      addTearDown(
        () => db.writer.execute('drop table if exists keta_conformance_lossy'),
      );
      await db.writer.execute(
        'insert into keta_conformance_lossy (id, amount) values (?, ?)',
        ['a', '12.10'],
      );
      final row = (await db.reader.query(
        'select amount from keta_conformance_lossy',
      )).single;
      // Not a String any more: the trailing digit is gone before any Dart code
      // sees it, which is exactly what capabilities.exactDecimal false means.
      expect(row['amount'], isA<num>());
      expect(() => row.decimalAt('amount'), throwsStateError);
    });

    test(
      'a timestamp reads back as the ISO 8601 string it was given',
      () async {
        const written = '2026-07-20T09:30:00Z';
        final row = await insertAndRead(
          id: 'a',
          flag: null,
          amount: null,
          at: written,
        );
        final read = row.timestampAt('at');
        expect(DateTime.parse(read), DateTime.parse(written));
        expect(row.tryTimestampAt('at'), read);
      },
    );

    test('an absent column is an error, distinct from a null one', () async {
      final row = (await db.reader.query('select id from keta_conformance'));
      await insertAndRead(id: 'a', flag: null, amount: null, at: null);
      expect(row, isEmpty);
      final one = (await db.reader.query(
        'select id from keta_conformance',
      )).single;
      expect(() => one.boolAt('flag'), throwsStateError);
      expect(() => one.tryBoolAt('flag'), throwsStateError);
    });

    test('a transaction commits on return and rolls back on throw', () async {
      await db.transaction((conn) async {
        await conn.execute('insert into keta_conformance (id) values (?)', [
          'committed',
        ]);
      });
      await expectLater(
        db.transaction((conn) async {
          await conn.execute('insert into keta_conformance (id) values (?)', [
            'rolled-back',
          ]);
          throw const Conflict('no');
        }),
        throwsA(isA<Conflict>()),
      );
      final rows = await db.reader.query(
        'select id from keta_conformance order by id',
      );
      expect(rows.map((r) => r['id']), ['committed']);
    });

    test('requireCapabilities refuses what this engine cannot hold and passes '
        'what it can', () async {
      final caps = db.capabilities;
      expect(
        () => db.requireCapabilities(exactDecimal: caps.exactDecimal),
        returnsNormally,
      );
      if (!caps.exactDecimal) {
        expect(
          () => db.requireCapabilities(exactDecimal: true),
          throwsStateError,
        );
      }
      if (!caps.nativeBool) {
        expect(
          () => db.requireCapabilities(nativeBool: true),
          throwsStateError,
        );
      }
    });
  });
}
