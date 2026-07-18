/// Pins applyMigrations' ordering, idempotency, ledger/checksum bookkeeping,
/// legacy-upgrade, and out-of-order rules against FakeDb.
library;

import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

import 'support/fake_db.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('keta_db_apply_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File m(String name, String sql) =>
      File('${dir.path}/$name')..writeAsStringSync(sql);

  group('applyMigrations', () {
    test(
      'applies in version order and records a UTC ISO-8601 applied_at',
      () async {
        m('0002_two.sql', 'create table two (id integer);');
        m('0001_one.sql', 'create table one (id integer);');
        final db = FakeDb();
        final before = DateTime.now().toUtc();

        final result = await applyMigrations(db, directory: dir.path);

        expect(result.applied, ['0001', '0002']);
        expect(result.alreadyApplied, isEmpty);
        expect(
          db.committed.first,
          startsWith('create table if not exists _keta_migrations'),
        );
        const insertSql =
            'insert into _keta_migrations (version, applied_at, checksum) '
            'values (?, ?, ?)';
        expect(db.committed.skip(1), [
          'create table one (id integer);',
          insertSql,
          'create table two (id integer);',
          insertSql,
        ]);
        for (final row in db.ledger) {
          final at = row['applied_at'] as String;
          expect(at, endsWith('Z'));
          final parsed = DateTime.parse(at);
          expect(parsed.isUtc, isTrue);
          expect(parsed.isBefore(before), isFalse);
          expect(parsed.isAfter(DateTime.now().toUtc()), isFalse);
        }
      },
    );

    test('is idempotent across runs', () async {
      m('0001_one.sql', 'create table one (id integer);');
      m('0002_two.sql', 'create table two (id integer);');
      final db = FakeDb();

      await applyMigrations(db, directory: dir.path);
      final second = await applyMigrations(db, directory: dir.path);

      expect(second.applied, isEmpty);
      expect(second.alreadyApplied, ['0001', '0002']);
      expect(
        db.committed.where((s) => s == 'create table one (id integer);').length,
        1,
      );
      expect(db.ledger, hasLength(2));
    });

    test('applies only the newly-added migrations', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb();
      await applyMigrations(db, directory: dir.path);

      m('0002_two.sql', 'create table two (id integer);');
      final result = await applyMigrations(db, directory: dir.path);
      expect(result.applied, ['0002']);
      expect(result.alreadyApplied, ['0001']);
    });

    test(
      'a failing migration commits neither its body nor its ledger row',
      () async {
        m('0001_one.sql', 'create table one (id integer);');
        m('0002_two.sql', 'create table two (id integer);');
        final db = FakeDb()..failOn = 'create table two';

        await expectLater(
          applyMigrations(db, directory: dir.path),
          throwsStateError,
        );
        expect(db.ledger.map((r) => r['version']), ['0001']);
        expect(db.committed, isNot(contains('create table two (id integer);')));

        // Forward-fix: clearing the failure lets the pending migration apply.
        db.failOn = null;
        final result = await applyMigrations(db, directory: dir.path);
        expect(result.applied, ['0002']);
        expect(result.alreadyApplied, ['0001']);
      },
    );

    test('a failing ledger insert rolls back the migration body too', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb()..failOn = 'insert into _keta_migrations';

      await expectLater(
        applyMigrations(db, directory: dir.path),
        throwsStateError,
      );
      expect(db.ledger, isEmpty);
      expect(db.committed, isNot(contains('create table one (id integer);')));
    });

    test(
      'an empty directory applies nothing and runs no transaction',
      () async {
        final db = FakeDb();
        final result = await applyMigrations(db, directory: dir.path);
        expect(result.applied, isEmpty);
        expect(result.alreadyApplied, isEmpty);
        expect(db.ledger, isEmpty);
        expect(db.committed, hasLength(1)); // only the ledger DDL
      },
    );

    test('a missing directory throws before touching the database', () async {
      final db = FakeDb();
      await expectLater(
        applyMigrations(db, directory: '${dir.path}/nope'),
        throwsA(isA<FileSystemException>()),
      );
      expect(db.committed, isEmpty);
    });

    test('records a 16-hex FNV checksum per applied migration', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb();
      await applyMigrations(db, directory: dir.path);

      final checksum = db.ledger.single['checksum'] as String?;
      expect(checksum, isNotNull);
      expect(checksum, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test(
      'routes every ledger read through the writer, never the reader',
      () async {
        m('0001_one.sql', 'create table one (id integer);');
        final db = FakeDb();
        await applyMigrations(db, directory: dir.path);

        // A read replica lags the writer right after this writes the ledger;
        // reading pending state off the reader would re-apply what just landed.
        expect(db.queries.map((q) => q.$1), everyElement('writer'));
        expect(db.queries, isNotEmpty);
      },
    );

    test('a renamed version (padding changed) does not re-apply', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb();
      await applyMigrations(db, directory: dir.path);

      // Rename 0001_one.sql -> 1_one.sql: same numeric version, so it is done.
      File('${dir.path}/0001_one.sql').deleteSync();
      m('1_one.sql', 'create table one (id integer);');
      final result = await applyMigrations(db, directory: dir.path);

      expect(result.applied, isEmpty);
      expect(result.alreadyApplied, ['1']);
      // Only the original body ran; the rename did not re-run it.
      expect(
        db.committed.where((s) => s == 'create table one (id integer);').length,
        1,
      );
    });

    group('out-of-order versions', () {
      test('a pending version below the highest applied is a hard error naming '
          'both', () async {
        m('0001_one.sql', 'create table one (id integer);');
        m('0003_three.sql', 'create table three (id integer);');
        final db = FakeDb();
        await applyMigrations(db, directory: dir.path);

        // A late-merged 0002 shows up after 0003 is already applied.
        m('0002_two.sql', 'create table two (id integer);');
        await expectLater(
          applyMigrations(db, directory: dir.path),
          throwsA(
            isA<StateError>()
                .having(
                  (e) => e.message,
                  'names the offender',
                  contains('0002'),
                )
                .having((e) => e.message, 'names the barrier', contains('3')),
          ),
        );
        // It did not slip in.
        expect(db.ledger.map((r) => r['version']), ['0001', '0003']);
      });

      test('allowOutOfOrder: true applies it deliberately', () async {
        m('0001_one.sql', 'create table one (id integer);');
        m('0003_three.sql', 'create table three (id integer);');
        final db = FakeDb();
        await applyMigrations(db, directory: dir.path);

        m('0002_two.sql', 'create table two (id integer);');
        final result = await applyMigrations(
          db,
          directory: dir.path,
          allowOutOfOrder: true,
        );
        expect(result.applied, ['0002']);
      });
    });

    test(
      'upgrades a legacy ledger with ALTER TABLE, keeping old rows NULL',
      () async {
        // A ledger written before the checksum column existed, with 0001 already
        // applied (NULL checksum).
        final db = FakeDb(legacyLedger: ['0001']);
        m('0001_one.sql', 'create table one (id integer);');
        m('0002_two.sql', 'create table two (id integer);');

        final result = await applyMigrations(db, directory: dir.path);

        expect(result.applied, ['0002']);
        expect(result.alreadyApplied, ['0001']);
        // The column was added in place.
        expect(
          db.committed,
          contains('alter table _keta_migrations add column checksum text'),
        );
        // The pre-existing row keeps its NULL; the newly-applied one is hashed.
        final byVersion = {
          for (final r in db.ledger) r['version']: r['checksum'],
        };
        expect(byVersion['0001'], isNull);
        expect(byVersion['0002'], matches(RegExp(r'^[0-9a-f]{16}$')));
      },
    );

    test(
      'a raw SQL error (not a KetaException) names the failing migration',
      () async {
        m('0001_one.sql', 'create table one (id integer);');
        m('0002_bad.sql', 'this is not valid sql;');
        // The FakeDb transaction fails the offending body with a plain StateError,
        // standing in for a driver's untranslated syntax error.
        final db = FakeDb()..failOn = 'this is not valid sql';

        await expectLater(
          applyMigrations(db, directory: dir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'names the migration',
              allOf(startsWith('migration 0002 failed:'), contains('injected')),
            ),
          ),
        );
      },
    );
  });
}
