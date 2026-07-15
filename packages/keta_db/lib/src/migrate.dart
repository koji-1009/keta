library;

import 'dart:io';

import 'package:keta/keta.dart' show KetaException;

import 'db.dart';

/// One migration file: `NNNN_name.sql`, identified by its numeric [version]
/// prefix and applied in ascending numeric order.
class Migration {
  const Migration(this.version, this.name, this.sql);
  final String version;
  final String name;
  final String sql;
}

/// The outcome of a migration run: the versions applied this run and those
/// already present.
class MigrationResult {
  const MigrationResult(this.applied, this.alreadyApplied);
  final List<String> applied;
  final List<String> alreadyApplied;
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
    try {
      await db.transaction((conn) async {
        // Delegate multi-statement parsing to the driver — a hand-rolled
        // splitter breaks on triggers and on `;`/`--` inside string literals.
        await conn.execute(m.sql);
        await conn.execute(
          'insert into _keta_migrations (version, applied_at) values (?, ?)',
          [m.version, DateTime.now().toUtc().toIso8601String()],
        );
        return 0;
      });
    } on KetaException catch (e) {
      // Adapters answer in HTTP terms because that is what a request needs, and
      // a migration is not a request: a bare `Conflict(409, row already exists)`
      // names no migration and no constraint, because toString() withholds
      // detail from clients that do not exist here. Boot failures are read by a
      // person at a terminal, so say the whole thing.
      throw StateError(
        'migration ${m.version} failed: ${e.message}'
        '${e.detail == null ? '' : ' (${e.detail})'}',
      );
    }
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
      throw FormatException('migration file must be named NNNN_name.sql', base);
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
  migrations.sort(
    (a, b) => int.parse(a.version).compareTo(int.parse(b.version)),
  );
  for (var i = 1; i < migrations.length; i++) {
    if (int.parse(migrations[i].version) ==
        int.parse(migrations[i - 1].version)) {
      throw FormatException(
        'duplicate migration version',
        migrations[i].version,
      );
    }
  }
  return migrations;
}

/// A read-only check that every migration in [directory] is recorded in the
/// `_keta_migrations` ledger — meant to be called inside `Env.boot`.
extension VerifyMigrations on Db {
  /// Throws a [StateError] naming the unapplied versions (and the command to
  /// apply them) when the schema is behind [directory], so an out-of-date
  /// database fails loudly once at boot rather than as a rain of per-request
  /// 500s. Unlike [applyMigrations] it never writes, so running it in every
  /// isolate concurrently is safe.
  Future<void> verifyMigrations([String directory = 'migrations']) async {
    final onDisk = loadMigrations(directory);
    Set<String> applied;
    try {
      final rows = await reader.query('select version from _keta_migrations');
      applied = {for (final row in rows) row['version'] as String};
    } on Object {
      // The ledger table does not exist yet (nothing has ever been applied):
      // treat it as empty rather than leaking a driver error. The pending list
      // below reports every migration as unapplied, which is the truth.
      applied = const {};
    }
    final pending = [
      for (final m in onDisk)
        if (!applied.contains(m.version)) m.version,
    ];
    if (pending.isNotEmpty) {
      throw StateError(
        'database schema is out of date: ${pending.length} unapplied '
        "migration(s) [${pending.join(', ')}]. Apply them with the driver's "
        'migrate tool, e.g. `dart run keta_sqlite:migrate`.',
      );
    }
  }
}
