import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('keta_db_load_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File m(String name, [String sql = 'select 1;']) =>
      File('${dir.path}/$name')..writeAsStringSync(sql);

  group('loadMigrations', () {
    test('a missing directory is a FileSystemException', () {
      final missing = '${dir.path}/nope';
      expect(
        () => loadMigrations(missing),
        throwsA(
          isA<FileSystemException>()
              .having(
                (e) => e.message,
                'message',
                'migrations directory not found',
              )
              .having((e) => e.path, 'path', missing),
        ),
      );
    });

    test('an empty directory yields no migrations', () {
      expect(loadMigrations(dir.path), isEmpty);
    });

    test('non-.sql files and sub-directories are ignored', () {
      m('README.md');
      m('0001_a.txt');
      Directory('${dir.path}/0009_sub.sql').createSync();
      expect(loadMigrations(dir.path), isEmpty);
    });

    test('the version, name, and sql are parsed off the filename', () {
      m('0002_add_users.sql', 'create table users (id integer);');
      m('0003_add_users_index.sql');
      final migrations = loadMigrations(dir.path);
      expect(migrations.map((x) => x.version), ['0002', '0003']);
      expect(migrations.first.name, 'add_users');
      expect(migrations.first.sql, 'create table users (id integer);');
      // Only the first underscore splits version from name.
      expect(migrations[1].name, 'add_users_index');
    });

    test('migrations are sorted by numeric version, not lexically', () {
      m('10_j.sql');
      m('2_b.sql');
      m('0001_a.sql');
      expect(loadMigrations(dir.path).map((x) => x.version), [
        '0001',
        '2',
        '10',
      ]);
    });

    test('a filename without an underscore is a FormatException', () {
      m('0001.sql');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'migration file must be named NNNN_name.sql',
              )
              .having((e) => e.source, 'source', '0001.sql'),
        ),
      );
    });

    test('a leading underscore is a FormatException', () {
      m('_init.sql');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'migration file must be named NNNN_name.sql',
              )
              .having((e) => e.source, 'source', '_init.sql'),
        ),
      );
    });

    test('an empty (or whitespace-only) migration file is rejected', () {
      m('0001_empty.sql', '   \n  \t\n');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'migration file is empty',
          ),
        ),
      );
    });

    test('a non-numeric version is a FormatException', () {
      m('abc_init.sql');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'migration version must be numeric',
              )
              .having((e) => e.source, 'source', 'abc'),
        ),
      );
    });

    test('an exactly-duplicated version string is rejected', () {
      m('0001_a.sql');
      m('0001_b.sql');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'duplicate migration version',
              )
              .having((e) => e.source, 'source', '0001'),
        ),
      );
    });

    test('versions that differ only by padding still collide numerically', () {
      m('0001_a.sql');
      m('1_b.sql');
      expect(
        () => loadMigrations(dir.path),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'duplicate migration version',
              )
              .having(
                (e) => int.parse(e.source as String),
                'numeric version',
                1,
              ),
        ),
      );
    });
  });
}
