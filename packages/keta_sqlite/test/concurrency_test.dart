/// Pins SqliteDb's transaction serialization: concurrent transactions queue
/// rather than interleave or lose updates, and a genuinely nested transaction
/// is a StateError.
library;

import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent transactions serialize — no nesting error, no lost updates',
    () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute(
        'create table counter (id integer primary key, n integer)',
      );
      await db.writer.execute('insert into counter values (1, 0)');

      // 1000 concurrent read-modify-write increments through transactions.
      // Without serialization this throws "transactions do not nest" and/or
      // loses updates.
      await Future.wait([
        for (var i = 0; i < 1000; i++)
          db.transaction((c) async {
            final rows = await c.query('select n from counter where id = 1');
            final n = rows.single['n'] as int;
            await c.execute('update counter set n = ? where id = 1', [n + 1]);
            return 0;
          }),
      ]);

      final n = (await db.reader.query(
        'select n from counter where id = 1',
      )).single['n'];
      expect(n, 1000);
    },
  );

  test(
    'a plain write concurrent with an open transaction does not interleave',
    () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table t (k text)');

      // A transaction that inserts then rolls back, racing a plain insert that
      // must NOT be swept into (and rolled back with) the transaction.
      final tx = db
          .transaction<int>((c) async {
            await c.execute("insert into t values ('tx')");
            await Future<void>.delayed(Duration.zero);
            throw StateError('rollback');
          })
          .catchError((_) => 0);
      final plain = db.writer.execute("insert into t values ('plain')");

      await Future.wait([tx, plain]);

      final rows = await db.reader.query('select k from t');
      expect(rows.map((r) => r['k']), ['plain']);
    },
  );

  test('a genuinely nested transaction is a StateError', () async {
    final db = SqliteDb.memory();
    addTearDown(db.close);
    await expectLater(
      db.transaction((_) => db.transaction((_) async => 0)),
      throwsStateError,
    );
  });
}
