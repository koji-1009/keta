/// Engine-backed counterpart to keta_db's FakeDb migration suites: the same
/// apply/verify/checksum/legacy-upgrade/out-of-order contracts, exercised
/// against a real SqliteDb so the fake's behavior is proven against sqlite3
/// itself (multi-statement bodies, triggers, real ALTER TABLE).
library;

import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

void main() {
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
        File(
          '${dir.path}/0001_one.sql',
        ).writeAsStringSync('create table one (id integer);');
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

    test(
      'upgrades a real pre-checksum ledger with ALTER TABLE (sqlite3 syntax)',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_alter');
        addTearDown(() => dir.deleteSync(recursive: true));
        File(
          '${dir.path}/0001_one.sql',
        ).writeAsStringSync('create table one (id integer);');
        final db = SqliteDb.memory();
        addTearDown(db.close);

        // Simulate a database migrated by an older keta_db: a ledger with the
        // old (no-checksum) shape and 0001 already applied.
        await db.writer.execute(
          'create table _keta_migrations '
          '(version text primary key, applied_at text not null)',
        );
        await db.writer.execute(
          'insert into _keta_migrations (version, applied_at) values '
          "('0001', '2020-01-01T00:00:00Z')",
        );
        await db.writer.execute('create table one (id integer)');

        File(
          '${dir.path}/0002_two.sql',
        ).writeAsStringSync('create table two (id integer);');

        // The real ALTER TABLE runs against sqlite3 here; 0002 applies and the
        // legacy 0001 row keeps its NULL checksum.
        final result = await applyMigrations(db, directory: dir.path);
        expect(result.applied, ['0002']);
        expect(result.alreadyApplied, ['0001']);
        final rows = await db.reader.query(
          'select version, checksum from _keta_migrations order by version',
        );
        expect(rows[0]['checksum'], isNull); // legacy 0001
        expect(rows[1]['checksum'], isNotNull); // freshly-hashed 0002

        // The NULL-checksum legacy row is accepted by verify.
        await expectLater(db.verifyMigrations(dir.path), completes);
      },
    );

    test('verify fails when an applied migration file was edited', () async {
      final dir = Directory.systemTemp.createTempSync('keta_drift');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/0001_one.sql')
        ..writeAsStringSync('create table one (id integer);');
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await applyMigrations(db, directory: dir.path);

      file.writeAsStringSync('create table one (id integer, extra text);');
      await expectLater(
        db.verifyMigrations(dir.path),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('checksum'))
              .having((e) => e.message, 'message', contains('0001')),
        ),
      );
    });

    test('an out-of-order pending version is a hard error', () async {
      final dir = Directory.systemTemp.createTempSync('keta_ooo');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/0001_one.sql',
      ).writeAsStringSync('create table one (id integer);');
      File(
        '${dir.path}/0003_three.sql',
      ).writeAsStringSync('create table three (id integer);');
      final db = SqliteDb.memory();
      addTearDown(db.close);
      await applyMigrations(db, directory: dir.path);

      File(
        '${dir.path}/0002_two.sql',
      ).writeAsStringSync('create table two (id integer);');
      await expectLater(
        applyMigrations(db, directory: dir.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('0002'),
          ),
        ),
      );
      // The escape hatch lets it through.
      await expectLater(
        applyMigrations(db, directory: dir.path, allowOutOfOrder: true),
        completes,
      );
    });
  });
}
