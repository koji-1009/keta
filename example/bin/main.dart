import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_example/app.dart';
import 'package:keta_example/env.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<void> main() async {
  // Configuration from the environment only (§9): DB path and port, with
  // sensible defaults. No config files are read at runtime.
  final dbPath = Platform.environment['KETA_DB_PATH'] ?? 'app.db';
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // Migrate once here, before any isolate boots: Env.boot runs per isolate, so
  // applying migrations there would race N connections onto the same file. A
  // single throwaway connection brings the schema up to date first.
  final migrator = SqliteDb.open(dbPath);
  final result = await applyMigrations(migrator, directory: 'migrations');
  await migrator.close();
  stdout.writeln(
    result.applied.isEmpty
        ? 'migrations: up to date'
        : 'migrations: applied ${result.applied.join(', ')}',
  );

  // serve boots one env per isolate; Env.boot is a static tear-off, so the same
  // call scales horizontally by raising `isolates`.
  final server = await buildApp().serve(Env.boot, port: port, isolates: 1);
  stdout.writeln('keta_example listening on :$port');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
