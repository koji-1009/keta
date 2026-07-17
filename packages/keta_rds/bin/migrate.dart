import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_rds/keta_rds.dart';

/// Applies pending SQL migrations to the PostgreSQL database named by `KETA_DB`.
///
/// The connection comes from the `KETA_DB` environment variable
/// (`postgres://user:pass@host:5432/db`, or `postgresql://...`); no config
/// files are read. An optional argument overrides the migrations directory
/// (default `migrations`). The runner lives in keta_db, but the bin ships here
/// because a pure keta_db bin cannot open a Postgres connection without a ring
/// cycle.
///
/// **Single-applier contract (spec §3).** `applyMigrations` assumes exactly one
/// concurrent applier. It is NOT self-arbitrating: keta ships no advisory-lock
/// coordination, so a multi-node deployment must serialize application
/// externally — a CI/CD step, an init container, or a dedicated job runs this
/// bin once, before any server isolate is spawned. The complementary read-only
/// `db.verifyMigrations(dir)` is what runs per node/isolate at boot (it never
/// writes, so N concurrent runs are safe) and fails loudly if the schema is
/// behind. Should two appliers race anyway, the `_keta_migrations` primary key
/// plus PostgreSQL's transactional DDL turns the collision into a loud failure,
/// not silent corruption.
Future<void> main(List<String> args) async {
  final url = Platform.environment['KETA_DB'];
  if (url == null) {
    stderr.writeln(
      'KETA_DB is not set (expected e.g. postgres://user:pass@host:5432/db)',
    );
    exit(64);
  }

  final String pgUrl;
  try {
    pgUrl = requirePostgresUrl(url);
  } on FormatException catch (e) {
    stderr.writeln(
      'keta_rds:migrate handles postgres:// URLs only; ${e.message}',
    );
    exit(64);
  }

  final db = RdsDb.url(pgUrl);
  try {
    final result = await applyMigrations(
      db,
      directory: args.isNotEmpty ? args.first : 'migrations',
    );
    stdout.writeln(
      result.applied.isEmpty
          ? 'no pending migrations (${result.alreadyApplied.length} already applied)'
          : 'applied ${result.applied.length}: ${result.applied.join(', ')}',
    );
  } finally {
    await db.close();
  }
}
