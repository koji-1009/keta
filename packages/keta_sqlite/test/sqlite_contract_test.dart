/// Pins SqliteDb's DbConn contract: type round-tripping, transaction
/// commit/rollback and failure handling, lifecycle, `run<T>` serialization,
/// and lock-acquisition timeout/close ordering.
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart' show Conflict, KetaException;
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

void main() {
  group('transaction commit/rollback', () {
    test('commits on success and rolls back on throw', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute(
        'create table users (id integer primary key, name text not null)',
      );

      await db.transaction((c) async {
        await c.execute('insert into users (name) values (?)', ['ada']);
        return 0;
      });
      expect(
        (await db.reader.query('select count(*) n from users')).single['n'],
        1,
      );

      await expectLater(
        db.transaction((c) async {
          await c.execute('insert into users (name) values (?)', ['grace']);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(
        (await db.reader.query('select count(*) n from users')).single['n'],
        1,
      );
    });
  });

  group('transaction failure handling', () {
    test('a failing ROLLBACK does not mask the original error', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table t (k text)');

      final sentinel = StateError('original');
      await expectLater(
        db.transaction((c) async {
          await c.execute("insert into t values ('x')");
          // End the transaction under keta's feet, so its own ROLLBACK throws.
          await c.execute('ROLLBACK');
          throw sentinel;
        }),
        throwsA(same(sentinel)),
      );

      // The connection survives: the insert rolled back and writes still work.
      expect(await db.reader.query('select k from t'), isEmpty);
      await db.writer.execute("insert into t values ('after')");
      expect(
        (await db.reader.query('select count(*) n from t')).single['n'],
        1,
      );
    });
  });

  group('error propagation', () {
    test('a uniqueness violation surfaces as Conflict, everything else as the '
        'driver saw it', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);

      // Bugs stay the driver's. The app cannot act on "you typed selec", so
      // dressing it up as a KetaException would only hide it.
      await expectLater(
        db.reader.query('selec nonsense'),
        throwsA(isA<SqliteException>()),
      );

      await db.writer.execute('create table u (name text not null unique)');
      await db.writer.execute("insert into u values ('a')");
      // A duplicate is the one constraint the caller can act on, and the
      // DbConn contract requires the adapter to say so in keta's vocabulary:
      // a handler answering 409 must not have to import package:sqlite3 and
      // match code 2067, which would couple it to this engine and break on
      // the next one.
      await expectLater(
        db.writer.execute("insert into u values ('a')"),
        throwsA(isA<Conflict>().having((e) => e.status, 'status', 409)),
      );
      // The boundary: NOT NULL is the app inserting wrong data — its own bug,
      // untranslated, and the 500 it earns is the honest answer.
      await expectLater(
        db.writer.execute('insert into u values (null)'),
        throwsA(
          isA<SqliteException>().having((e) => e.resultCode, 'resultCode', 19),
        ),
      );
    });
  });

  group('SqliteDb.open', () {
    test('persists across close and reopen', () async {
      final dir = Directory.systemTemp.createTempSync('keta_sqlite');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';

      final db1 = SqliteDb.open(path);
      await db1.writer.execute('create table t (k text)');
      await db1.writer.execute("insert into t values ('persisted')");
      await db1.close();

      final db2 = SqliteDb.open(path);
      addTearDown(db2.close);
      expect(
        (await db2.reader.query('select k from t')).single['k'],
        'persisted',
      );
    });
  });

  group('the DbConn contract', () {
    test('execute and query round-trip with the type contract', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute(
        'create table t (i integer, r real, s text, b blob)',
      );
      final affected = await db.writer.execute(
        'insert into t values (?, ?, ?, ?)',
        [
          7,
          1.5,
          'hi',
          [1, 2, 3],
        ],
      );
      expect(affected, 1);

      final rows = await db.reader.query('select * from t');
      expect(rows.single['i'], 7);
      expect(rows.single['r'], 1.5);
      expect(rows.single['s'], 'hi');
      expect(rows.single['b'], [1, 2, 3]);
    });

    test('execute returns the affected row count', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table t (n integer)');
      for (var i = 0; i < 3; i++) {
        await db.writer.execute('insert into t values (?)', [i]);
      }
      expect(await db.writer.execute('update t set n = n + 10'), 3);
      expect(await db.writer.execute('delete from t where n = 999'), 0);
      expect(await db.writer.execute('delete from t'), 3);
    });

    test('a query with no matching rows returns an empty list', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table t (n integer)');
      final rows = await db.reader.query('select * from t where 1 = 0');
      expect(rows, isA<List<Map<String, Object?>>>());
      expect(rows, isEmpty);
    });

    test('NULL round-trips as Dart null (present, not absent)', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table t (a text, b integer)');
      await db.writer.execute('insert into t values (?, ?)', [null, null]);
      final row = (await db.reader.query('select a, b from t')).single;
      expect(row.containsKey('a'), isTrue);
      expect(row['a'], isNull);
      expect(row['b'], isNull);
    });

    test(
      'decimal/numeric columns come back as double for fractional values',
      () async {
        final db = SqliteDb.memory();
        addTearDown(db.close);
        await db.writer.execute('create table d (v decimal(10, 2), n numeric)');
        await db.writer.execute('insert into d values (?, ?)', [12.34, 0.5]);
        final row = (await db.reader.query('select v, n from d')).single;
        expect(row['v'], isA<double>());
        expect(row['v'], 12.34);
        expect(row['n'], isA<double>());

        // NUMERIC affinity collapses a lossless double to int — recorded as spec.
        await db.writer.execute('insert into d values (?, ?)', [5.0, 5.0]);
        expect(
          (await db.reader.query('select v from d where v = 5')).single['v'],
          isA<int>(),
        );
      },
    );

    test('BLOB results are fixed-length lists', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await db.writer.execute('create table b (x blob)');
      await db.writer.execute('insert into b values (?)', [
        [1, 2, 3],
      ]);
      final blob =
          (await db.reader.query('select x from b')).single['x'] as List<int>;
      expect(blob, [1, 2, 3]);
      expect(() => blob.add(4), throwsUnsupportedError);
    });
  });

  group('lifecycle', () {
    test(
      'close is idempotent and post-close operations throw StateError',
      () async {
        final db = SqliteDb.memory();
        await db.writer.execute('create table t (k text)');
        await db.close();
        await db.close(); // idempotent: must not throw
        await expectLater(db.reader.query('select 1'), throwsStateError);
        await expectLater(
          db.writer.execute("insert into t values ('x')"),
          throwsStateError,
        );
      },
    );
  });

  group('run<T> serialization', () {
    test('serializes actions outside a transaction', () async {
      final db = SqliteDb.memory();
      addTearDown(db.close);
      final order = <String>[];
      final a = db.run(() async {
        order.add('a-start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('a-end');
      });
      final b = db.run(() => order.add('b'));
      await Future.wait([a, b]);
      expect(order, ['a-start', 'a-end', 'b']);
    });

    test(
      'inside the transaction zone does not re-lock (no deadlock)',
      () async {
        final db = SqliteDb.memory();
        addTearDown(db.close);
        final result = await db
            .transaction((c) {
              return db.run(() => db.rawQuery('select 1 as one', []));
            })
            .timeout(const Duration(seconds: 5));
        expect(result.single['one'], 1);
      },
    );

    test(
      'a captured transaction zone cannot bypass the lock to dirty-read',
      () async {
        final db = SqliteDb.memory();
        addTearDown(db.close);
        await db.writer.execute('create table t (n integer)');

        // Capture a zone from inside a committed transaction.
        late Zone stale;
        await db.transaction((c) async {
          stale = Zone.current;
          return 0;
        });

        // A second transaction inserts, then rolls back, held open by the gate.
        final gate = Completer<void>();
        final tx2 = db.transaction<int>((c) async {
          await c.execute('insert into t values (1)');
          await gate.future;
          throw StateError('roll back');
        });

        // Reading via the stale zone must queue behind tx2 (not take the shortcut),
        // so it sees committed state (0 rows), never tx2's uncommitted row.
        var seen = -1;
        final probe = stale
            .run(() => db.reader.query('select count(*) n from t'))
            .then((rows) => seen = rows.single['n'] as int);

        gate.complete();
        await tx2.catchError((Object _) => 0);
        await probe;
        expect(seen, 0);
      },
    );
  });

  group('lock acquisition timeout', () {
    test(
      'a hung transaction makes a waiting statement 503, not deadlock',
      () async {
        final db = SqliteDb.memory(
          lockTimeout: const Duration(milliseconds: 50),
        );
        await db.writer.execute('create table t (n integer)');
        final gate = Completer<void>();
        // A transaction that does not return holds the single-writer lock.
        final hung = db.transaction<int>((c) async {
          await c.execute('insert into t values (1)');
          await gate.future;
          return 0;
        });

        // A statement that cannot acquire the lock within lockTimeout fails loud.
        await expectLater(
          db.reader.query('select 1'),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 503)),
        );

        gate.complete(); // release the hung tx so the test ends cleanly
        await hung;
        await db.close();
      },
    );
  });

  group('close ordering', () {
    test(
      'close waits for an in-flight transaction (does not kill it)',
      () async {
        final db = SqliteDb.memory();
        await db.writer.execute('create table t (n integer)');
        final gate = Completer<void>();
        final tx = db.transaction((c) async {
          await c.execute('insert into t values (1)');
          await gate.future;
          return 'ok';
        });
        final closed = db.close(); // must queue behind the tx, not preempt it
        gate.complete();
        expect(await tx, 'ok'); // committed, not killed mid-flight
        await closed;
      },
    );
  });
}
