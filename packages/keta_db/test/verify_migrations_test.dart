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
  });
}
