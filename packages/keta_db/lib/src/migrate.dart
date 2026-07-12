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
      // Delegate multi-statement parsing to the driver — a hand-rolled splitter
      // breaks on triggers and on `;`/`--` inside string literals.
      await conn.execute(m.sql);
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
/// by numeric version. A missing directory is an error (usually a typo or wrong
/// cwd), not a silent success; duplicate numeric versions are rejected.
List<Migration> loadMigrations(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) {
    throw FileSystemException('migrations directory not found', directory);
  }
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
    final sql = file.readAsStringSync();
    // An empty (or whitespace-only) migration is almost always a truncated or
    // unsaved file. Recording it as "applied" would silently make it a no-op
    // that can never be re-run, so reject it up front.
    if (sql.trim().isEmpty) {
      throw FormatException('migration file is empty', base);
    }
    migrations.add(Migration(version, stem.substring(underscore + 1), sql));
  }
  migrations.sort((a, b) => int.parse(a.version).compareTo(int.parse(b.version)));
  for (var i = 1; i < migrations.length; i++) {
    if (int.parse(migrations[i].version) ==
        int.parse(migrations[i - 1].version)) {
      throw FormatException(
          'duplicate migration version', migrations[i].version);
    }
  }
  return migrations;
}
