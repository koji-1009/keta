/// Pins verifyMigrations' pending/applied detection, checksum-drift and
/// legacy-NULL-checksum handling, and writer-routed reads against FakeDb.
library;

import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

import 'support/fake_db.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('keta_db_verify_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File m(String name, String sql) =>
      File('${dir.path}/$name')..writeAsStringSync(sql);

  group('verifyMigrations', () {
    test('passes once every migration is applied', () async {
      m('0001_one.sql', 'create table one (id integer);');
      m('0002_two.sql', 'create table two (id integer);');
      final db = FakeDb();
      await applyMigrations(db, directory: dir.path);

      await expectLater(db.verifyMigrations(dir.path), completes);
    });

    test('an empty directory has nothing to verify', () async {
      await expectLater(FakeDb().verifyMigrations(dir.path), completes);
    });

    test('an unmigrated database names every pending version and the '
        'command to run', () async {
      m('0001_one.sql', 'create table one (id integer);');
      m('0002_two.sql', 'create table two (id integer);');

      await expectLater(
        FakeDb().verifyMigrations(dir.path),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('0001'))
              .having((e) => e.message, 'message', contains('0002'))
              .having(
                (e) => e.message,
                'message',
                contains('dart run keta_sqlite:migrate'),
              ),
        ),
      );
    });

    test(
      'a partially-applied schema reports only the missing versions',
      () async {
        m('0001_one.sql', 'create table one (id integer);');
        final db = FakeDb();
        await applyMigrations(db, directory: dir.path);
        m('0002_two.sql', 'create table two (id integer);');

        await expectLater(
          db.verifyMigrations(dir.path),
          throwsA(
            isA<StateError>()
                .having((e) => e.message, 'message', contains('0002'))
                .having((e) => e.message, 'message', isNot(contains('0001'))),
          ),
        );
      },
    );

    test(
      'a missing directory throws (a typo or wrong cwd, not clean)',
      () async {
        await expectLater(
          FakeDb().verifyMigrations('${dir.path}/nope'),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('an edited already-applied file fails, naming the version', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb();
      await applyMigrations(db, directory: dir.path);

      // Edit the applied file: its checksum no longer matches the ledger.
      m('0001_one.sql', 'create table one (id integer, extra text);');

      await expectLater(
        db.verifyMigrations(dir.path),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('checksum'))
              .having((e) => e.message, 'names the version', contains('0001')),
        ),
      );
    });

    test(
      'a legacy NULL checksum is accepted (verify cannot vouch for it)',
      () async {
        // A ledger row applied before checksums were tracked (NULL checksum),
        // its file present and unchanged on disk.
        final db = FakeDb(legacyLedger: ['0001']);
        m('0001_one.sql', 'create table one (id integer);');

        await expectLater(db.verifyMigrations(dir.path), completes);
      },
    );

    test(
      'routes every ledger read through the writer, never the reader',
      () async {
        m('0001_one.sql', 'create table one (id integer);');
        final db = FakeDb();
        await applyMigrations(db, directory: dir.path);
        db.queries.clear();

        await db.verifyMigrations(dir.path);
        // Replica lag right after a deploy's migration step would false-fail a
        // reader-routed verify; every read must hit the writer.
        expect(db.queries.map((q) => q.$1), everyElement('writer'));
        expect(db.queries, isNotEmpty);
      },
    );

    test('an unreachable database surfaces its own error, not a '
        'pending-migrations StateError', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb()..unreachable = StateError('connection closed');

      // Before the connectivity probe, this failure was indistinguishable
      // from "the ledger table does not exist" and got reported as 1
      // unapplied migration — hiding the real problem (the db is
      // unreachable) behind a misleading one.
      await expectLater(
        db.verifyMigrations(dir.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'connection closed',
          ),
        ),
      );
    });
  });
}
