/// Pins SqliteDb's constraint-error translation: uniqueness violations become
/// Conflict (detail kept server-side, hidden from the client); everything
/// else stays the driver's own error.
library;

import 'package:keta/keta.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:sqlite3/sqlite3.dart' show SqlExtendedError, SqliteException;
import 'package:test/test.dart';

Future<SqliteDb> boot() async {
  final db = SqliteDb.memory();
  await db.writer.execute(
    'create table t (id text primary key, email text unique, n int not null)',
  );
  await db.writer.execute('insert into t values (?, ?, ?)', ['1', 'a@x', 1]);
  return db;
}

void main() {
  // The Db contract is driver-agnostic. If a duplicate key surfaced as the
  // driver's own SqliteException, every handler wanting a 409 would have to
  // import package:sqlite3 and match code 1555 — coupling the app to this
  // engine and breaking it on the next one.

  test(
    'a duplicate primary key is a Conflict, not a driver exception',
    () async {
      final db = await boot();
      addTearDown(db.close);
      await expectLater(
        db.writer.execute('insert into t values (?, ?, ?)', ['1', 'b@x', 2]),
        throwsA(
          isA<Conflict>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.message, 'message', 'row already exists'),
        ),
      );
    },
  );

  test('a duplicate unique index is a Conflict too', () async {
    final db = await boot();
    addTearDown(db.close);
    await expectLater(
      db.writer.execute('insert into t values (?, ?, ?)', ['2', 'a@x', 2]),
      throwsA(isA<Conflict>()),
    );
  });

  test(
    'the collision detail is carried, but not shown to the client',
    () async {
      final db = await boot();
      addTearDown(db.close);
      try {
        await db.writer.execute('insert into t values (?, ?, ?)', [
          '1',
          'b@x',
          2,
        ]);
        fail('expected a Conflict');
      } on Conflict catch (e) {
        // The operator needs to know which constraint collided...
        expect(e.detail.toString(), contains('UNIQUE constraint failed'));
        // ...and the client does not.
        expect(e.toString(), isNot(contains('UNIQUE constraint failed')));
      }
    },
  );

  test('inside a transaction it is still a Conflict', () async {
    final db = await boot();
    addTearDown(db.close);
    await expectLater(
      db.transaction(
        (c) => c.execute('insert into t values (?, ?, ?)', ['1', 'b@x', 2]),
      ),
      throwsA(isA<Conflict>()),
    );
    // The failed transaction rolled back rather than leaving a half-written row.
    expect(await db.reader.query('select * from t'), hasLength(1));
  });

  test('a non-uniqueness constraint is left alone', () async {
    final db = await boot();
    addTearDown(db.close);
    // NOT NULL is the app inserting wrong data — its own bug. Mapping it to 409
    // would tell the client to retry something that can never succeed, so it
    // stays the driver's error and the 500 it earns.
    await expectLater(
      db.writer.execute('insert into t values (?, ?, ?)', ['9', 'c@x', null]),
      throwsA(
        isA<SqliteException>().having(
          (e) => e.extendedResultCode,
          'extendedResultCode',
          SqlExtendedError.SQLITE_CONSTRAINT_NOTNULL,
        ),
      ),
    );
    // And it is emphatically not a KetaException: `isA<SqliteException>()`
    // alone would still pass if the translation swallowed this, because
    // narrowing `e` to SqliteException makes `e is Conflict` a compile-time
    // false — a matcher that reads like a guard and can never fire.
    await expectLater(
      db.writer.execute('insert into t values (?, ?, ?)', ['8', 'd@x', null]),
      throwsA(isNot(isA<KetaException>())),
    );
  });

  test('a query that violates nothing is unaffected', () async {
    final db = await boot();
    addTearDown(db.close);
    expect(await db.reader.query('select id from t'), [
      {'id': '1'},
    ]);
  });
}
