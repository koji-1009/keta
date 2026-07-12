import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

import 'support/fake_db.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('keta_db_apply_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File m(String name, String sql) => File('${dir.path}/$name')
    ..writeAsStringSync(sql);

  group('applyMigrations', () {
    test('applies in version order and records a UTC ISO-8601 applied_at',
        () async {
      m('0002_two.sql', 'create table two (id integer);');
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb();
      final before = DateTime.now().toUtc();

      final result = await applyMigrations(db, directory: dir.path);

      expect(result.applied, ['0001', '0002']);
      expect(result.alreadyApplied, isEmpty);
      expect(db.committed.first,
          startsWith('create table if not exists _keta_migrations'));
      expect(db.committed.skip(1), [
        'create table one (id integer);',
        'insert into _keta_migrations (version, applied_at) values (?, ?)',
        'create table two (id integer);',
        'insert into _keta_migrations (version, applied_at) values (?, ?)',
      ]);
      for (final row in db.ledger) {
        final at = row['applied_at'] as String;
        expect(at, endsWith('Z'));
        final parsed = DateTime.parse(at);
        expect(parsed.isUtc, isTrue);
        expect(parsed.isBefore(before), isFalse);
        expect(parsed.isAfter(DateTime.now().toUtc()), isFalse);
      }
    });

    test('is idempotent across runs', () async {
      m('0001_one.sql', 'create table one (id integer);');
      m('0002_two.sql', 'create table two (id integer);');
      final db = FakeDb();

      await applyMigrations(db, directory: dir.path);
      final second = await applyMigrations(db, directory: dir.path);

      expect(second.applied, isEmpty);
      expect(second.alreadyApplied, ['0001', '0002']);
      expect(
          db.committed
              .where((s) => s == 'create table one (id integer);')
              .length,
          1);
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

    test('a failing migration commits neither its body nor its ledger row',
        () async {
      m('0001_one.sql', 'create table one (id integer);');
      m('0002_two.sql', 'create table two (id integer);');
      final db = FakeDb()..failOn = 'create table two';

      await expectLater(
          applyMigrations(db, directory: dir.path), throwsStateError);
      expect(db.ledger.map((r) => r['version']), ['0001']);
      expect(db.committed, isNot(contains('create table two (id integer);')));

      // Forward-fix: clearing the failure lets the pending migration apply.
      db.failOn = null;
      final result = await applyMigrations(db, directory: dir.path);
      expect(result.applied, ['0002']);
      expect(result.alreadyApplied, ['0001']);
    });

    test('a failing ledger insert rolls back the migration body too', () async {
      m('0001_one.sql', 'create table one (id integer);');
      final db = FakeDb()..failOn = 'insert into _keta_migrations';

      await expectLater(
          applyMigrations(db, directory: dir.path), throwsStateError);
      expect(db.ledger, isEmpty);
      expect(db.committed, isNot(contains('create table one (id integer);')));
    });

    test('an empty directory applies nothing and runs no transaction',
        () async {
      final db = FakeDb();
      final result = await applyMigrations(db, directory: dir.path);
      expect(result.applied, isEmpty);
      expect(result.alreadyApplied, isEmpty);
      expect(db.ledger, isEmpty);
      expect(db.committed, hasLength(1)); // only the ledger DDL
    });

    test('a missing directory throws before touching the database', () async {
      final db = FakeDb();
      await expectLater(
        applyMigrations(db, directory: '${dir.path}/nope'),
        throwsA(isA<FileSystemException>()),
      );
      expect(db.committed, isEmpty);
    });
  });
}
