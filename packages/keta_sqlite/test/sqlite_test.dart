import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

class Env implements HasLog, HasDb, Disposable {
  Env(this.log, this.db);
  @override
  final Log log;
  @override
  final Db db;

  @override
  Future<void> close() => db.close();
}

Future<Env> bootMemory() async {
  final db = SqliteDb.memory();
  await db.writer.execute(
    'create table users (id integer primary key, name text not null)',
  );
  return Env(StdoutLog(flushInterval: Duration.zero), db);
}

void main() {
  group('SqliteDb', () {
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

    test('transaction commits on success and rolls back on throw', () async {
      final env = await bootMemory();
      addTearDown(env.close);
      final db = env.db;

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

    test('nested transaction is a StateError', () async {
      final env = await bootMemory();
      addTearDown(env.close);
      await expectLater(
        env.db.transaction((_) => env.db.transaction((_) async => 0)),
        throwsStateError,
      );
    });
  });

  group('tx() middleware', () {
    testBothModes('rolls back the transaction when the handler fails', (
      mode,
    ) async {
      final env = await bootMemory();
      addTearDown(env.close);
      final app = App<Env>()
        ..use(recover())
        ..use(tx());
      app.post('/ok', (c) async {
        await c.get(txConn).execute('insert into users (name) values (?)', [
          'ok',
        ]);
        return c.text('done', status: 201);
      });
      app.post(
        '/fail',
        (Context<Env> c) => mode.wrap(() async {
          await c.get(txConn).execute('insert into users (name) values (?)', [
            'nope',
          ]);
          throw const BadRequest('rejected');
        })(),
      );
      final client = TestClient(app, env);

      expect((await client.post('/ok')).status, 201);
      expect((await client.post('/fail')).status, 400);

      final n = (await env.db.reader.query(
        'select count(*) n from users',
      )).single['n'];
      expect(n, 1); // only the committed /ok insert survives
    });
  });

  group('migrations', () {
    test('apply in order, record, and stay idempotent', () async {
      final dir = Directory.systemTemp.createTempSync('keta_mig');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/0002_add_email.sql',
      ).writeAsStringSync('alter table users add column email text;');
      File('${dir.path}/0001_create_users.sql').writeAsStringSync(
        'create table users (id integer primary key, name text);',
      );

      final db = SqliteDb.memory();
      addTearDown(db.close);

      final first = await applyMigrations(db, directory: dir.path);
      expect(first.applied, ['0001', '0002']);

      // The email column exists only if 0002 ran after 0001.
      await db.writer.execute(
        "insert into users (name, email) values ('a', 'a@b.c')",
      );
      final rows = await db.reader.query('select email from users');
      expect(rows.single['email'], 'a@b.c');

      final second = await applyMigrations(db, directory: dir.path);
      expect(second.applied, isEmpty);
      expect(second.alreadyApplied, ['0001', '0002']);
    });

    test(
      'applies a migration containing a trigger (multi-statement)',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_trig');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/0001_trigger.sql').writeAsStringSync('''
create table t (id integer primary key, n integer);
create table audit (n integer);
create trigger t_ins after insert on t begin
  insert into audit (n) values (new.n);
end;
''');
        final db = SqliteDb.memory();
        addTearDown(db.close);

        final result = await applyMigrations(db, directory: dir.path);
        expect(result.applied, ['0001']);

        await db.writer.execute('insert into t (n) values (5)');
        expect((await db.reader.query('select n from audit')).single['n'], 5);
      },
    );

    test(
      'verifyMigrations throws on a never-migrated db (no ledger table)',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_verify');
        addTearDown(() => dir.deleteSync(recursive: true));
        File('${dir.path}/0001_one.sql').writeAsStringSync(
          'create table one (id integer);',
        );
        final db = SqliteDb.memory();
        addTearDown(db.close);

        // The `_keta_migrations` table does not exist yet, so the ledger read
        // throws inside verifyMigrations — it must surface as the pending-schema
        // StateError, not the raw driver error.
        await expectLater(
          db.verifyMigrations(dir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('0001'),
            ),
          ),
        );
      },
    );

    test('verifyMigrations passes once migrations are applied', () async {
      final dir = Directory.systemTemp.createTempSync('keta_verify_ok');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/0001_one.sql',
      ).writeAsStringSync('create table one (id integer);');
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await applyMigrations(db, directory: dir.path);

      await expectLater(db.verifyMigrations(dir.path), completes);
    });
  });
}
