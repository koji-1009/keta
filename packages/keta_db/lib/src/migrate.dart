library;

import 'dart:io';

import 'db.dart';

/// One migration file: `NNNN_name.sql`, identified by its numeric [version]
/// prefix and applied in ascending numeric order.
class Migration {
  final String version;
  final String name;
  final String sql;

  const Migration(this.version, this.name, this.sql);
}

/// The outcome of a migration run: the versions applied this run and those
/// already present.
class MigrationResult {
  final List<String> applied;
  final List<String> alreadyApplied;

  const MigrationResult(this.applied, this.alreadyApplied);
}

/// Applies pending migrations from [directory] to [db] in ascending version
/// order, recording each in the `_keta_migrations` table so it runs at most
/// once. Each migration and its bookkeeping row commit together, so a failure
/// leaves the schema exactly at the last fully-applied version. There is no
/// rollback path — fixes go forward.
Future<MigrationResult> applyMigrations(
  Db db, {
  String directory = 'migrations',
}) async {
  final migrations = loadMigrations(directory);

  await db.writer.execute(
    'create table if not exists _keta_migrations '
    '(version text primary key, applied_at text not null)',
  );
  final rows = await db.reader.query('select version from _keta_migrations');
  final done = {for (final r in rows) r['version'] as String};

  final applied = <String>[];
  final skipped = <String>[];
  for (final m in migrations) {
    if (done.contains(m.version)) {
      skipped.add(m.version);
      continue;
    }
    await db.transaction((conn) async {
      for (final statement in splitStatements(m.sql)) {
        await conn.execute(statement);
      }
      await conn.execute(
        'insert into _keta_migrations (version, applied_at) values (?, ?)',
        [m.version, DateTime.now().toUtc().toIso8601String()],
      );
      return 0;
    });
    applied.add(m.version);
  }
  return MigrationResult(applied, skipped);
}

/// Reads and parses `NNNN_name.sql` files under [directory], sorted ascending
/// by numeric version. A missing directory yields no migrations.
List<Migration> loadMigrations(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) return const [];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList();
  final migrations = <Migration>[];
  for (final file in files) {
    final base = file.uri.pathSegments.last;
    final stem = base.substring(0, base.length - '.sql'.length);
    final underscore = stem.indexOf('_');
    if (underscore <= 0) {
      throw FormatException(
          'migration file must be named NNNN_name.sql', base);
    }
    final version = stem.substring(0, underscore);
    if (int.tryParse(version) == null) {
      throw FormatException('migration version must be numeric', version);
    }
    migrations.add(
        Migration(version, stem.substring(underscore + 1), file.readAsStringSync()));
  }
  migrations.sort((a, b) => int.parse(a.version).compareTo(int.parse(b.version)));
  return migrations;
}

/// Splits a SQL script into individual statements, dropping `--` line comments
/// and blank statements. It splits on `;` and does not account for semicolons
/// inside string literals, which migration DDL does not use.
List<String> splitStatements(String sql) {
  final withoutComments = sql
      .split('\n')
      .map((line) {
        final comment = line.indexOf('--');
        return comment == -1 ? line : line.substring(0, comment);
      })
      .join('\n');
  return [
    for (final part in withoutComments.split(';'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
