import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

/// Applies pending SQL migrations to the SQLite database named by `KETA_DB`.
///
/// The connection comes from the `KETA_DB` environment variable
/// (`sqlite:path/to.db` or `sqlite::memory:`); no config files are read. An
/// optional argument overrides the migrations directory (default `migrations`).
///
/// **Single-applier contract**: run this once, from one place, before the
/// serving fleet boots (a CI/CD step, an init container, a dedicated job).
/// It assumes exactly one concurrent applier and takes no advisory lock — two
/// invocations racing the same database can both see a version as pending and
/// both attempt it. Each node/isolate instead calls `db.verifyMigrations()` at
/// boot (read-only, safe to run everywhere) to confirm the schema is current;
/// see [applyMigrations]'s doc comment for the full division of labour.
Future<void> main(List<String> args) async {
  final url = Platform.environment['KETA_DB'];
  if (url == null) {
    stderr.writeln('KETA_DB is not set (expected e.g. sqlite:app.db)');
    exit(64);
  }
  const prefix = 'sqlite:';
  if (!url.startsWith(prefix)) {
    stderr.writeln('keta_sqlite:migrate handles sqlite: URLs only; got "$url"');
    exit(64);
  }
  final path = url.substring(prefix.length);
  final db = path == ':memory:' ? SqliteDb.memory() : SqliteDb.open(path);
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
