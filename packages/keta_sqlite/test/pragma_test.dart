import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart' show KetaException, Unavailable;
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:sqlite3/sqlite3.dart' show SqlExtendedError, SqliteException;
import 'package:test/test.dart';

void main() {
  group('foreign_keys PRAGMA', () {
    Future<SqliteDb> bootWithFk() async {
      final db = SqliteDb.memory();
      await db.writer.execute('create table parent (id integer primary key)');
      await db.writer.execute(
        'create table child '
        '(id integer primary key, parent_id integer references parent(id))',
      );
      return db;
    }

    test(
      'a FOREIGN KEY violation is rejected, not silently accepted',
      () async {
        final db = await bootWithFk();
        addTearDown(db.close);
        // Without `PRAGMA foreign_keys = ON` sqlite3 accepts this insert
        // outright (the FK clause is parsed but never enforced) — the whole
        // point of this PRAGMA is that it no longer does.
        await expectLater(
          db.writer.execute('insert into child values (1, 999)'),
          throwsA(isA<SqliteException>()),
        );
        expect(await db.reader.query('select * from child'), isEmpty);
      },
    );

    test(
      'the violation stays a raw SqliteException, not a translated Conflict',
      () async {
        final db = await bootWithFk();
        addTearDown(db.close);
        // Same reasoning as NOT NULL/CHECK (see conflict_test.dart): a foreign
        // key violation is the app inserting wrong data, its own bug. A 409
        // would tell the client to retry something that can never succeed, so
        // this is deliberately left untranslated and earns the honest 500.
        await expectLater(
          db.writer.execute('insert into child values (1, 999)'),
          throwsA(
            isA<SqliteException>()
                .having((e) => e.resultCode, 'resultCode', 19)
                .having(
                  (e) => e.extendedResultCode,
                  'extendedResultCode',
                  SqlExtendedError.SQLITE_CONSTRAINT_FOREIGNKEY,
                ),
          ),
        );
        await expectLater(
          db.writer.execute('insert into child values (2, 998)'),
          throwsA(isNot(isA<KetaException>())),
        );
      },
    );

    test('a valid reference is accepted normally', () async {
      final db = await bootWithFk();
      addTearDown(db.close);
      await db.writer.execute('insert into parent values (1)');
      await db.writer.execute('insert into child values (1, 1)');
      expect(await db.reader.query('select * from child'), hasLength(1));
    });
  });

  group('WAL journal mode (opt-in)', () {
    test(
      'a file-backed db opened with wal:true reports journal_mode wal',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_wal');
        addTearDown(() => dir.deleteSync(recursive: true));
        final db = SqliteDb.open('${dir.path}/app.db', wal: true);
        addTearDown(db.close);

        final rows = await db.reader.query('PRAGMA journal_mode');
        expect(rows.single.values.single, 'wal');
      },
    );

    test(
      'the default (no wal) leaves the file on the rollback journal',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_wal');
        addTearDown(() => dir.deleteSync(recursive: true));
        final db = SqliteDb.open('${dir.path}/app.db');
        addTearDown(db.close);

        final mode = (await db.reader.query(
          'PRAGMA journal_mode',
        )).single.values.single;
        // Whatever SQLite's file default is, it is not WAL unless asked for.
        expect(mode, isNot('wal'));
      },
    );

    test('memory(wal: true) still opens a working in-memory db', () async {
      // WAL is a no-op for :memory: (no file for the -wal/-shm index); the flag
      // is accepted and the database works normally, staying on 'memory' mode.
      final db = SqliteDb.memory(wal: true);
      addTearDown(db.close);
      await db.writer.execute('create table t (n integer)');
      await db.writer.execute('insert into t values (1)');
      expect((await db.reader.query('select n from t')).single['n'], 1);
      expect(
        (await db.reader.query('PRAGMA journal_mode')).single.values.single,
        'memory',
      );
    });
  });

  group('busy_timeout PRAGMA / cross-connection SQLITE_BUSY', () {
    test('a second connection contending for the write lock gets Unavailable, '
        'not a raw SqliteException', () async {
      final dir = Directory.systemTemp.createTempSync('keta_busy');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';

      final holder = SqliteDb.open(path);
      addTearDown(holder.close);
      await holder.writer.execute('create table t (n integer)');

      // Hold an open write transaction on `holder`'s connection: the insert
      // below actually takes SQLite's write lock, and the transaction does
      // not commit until `gate` is released.
      final locked = Completer<void>();
      final gate = Completer<void>();
      final held = holder.transaction<int>((c) async {
        await c.execute('insert into t values (1)');
        locked.complete();
        await gate.future;
        return 0;
      });
      await locked.future;

      // A second, independent connection to the same file, with a very
      // short lockTimeout/busy_timeout so the test does not wait 30s.
      final contender = SqliteDb.open(
        path,
        lockTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(contender.close);

      await expectLater(
        contender.writer.execute('insert into t values (2)'),
        throwsA(isA<Unavailable>().having((e) => e.status, 'status', 503)),
      );

      gate.complete();
      await held;
    });
  });
}
