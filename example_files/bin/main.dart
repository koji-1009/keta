import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/routes.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<void> main() async {
  // Same lifecycle and config as the register-based example: env vars only,
  // migrate once before serve.
  final dbPath = Platform.environment['KETA_DB_PATH'] ?? 'app.db';
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final migrator = SqliteDb.open(dbPath);
  final result = await applyMigrations(migrator, directory: 'migrations');
  await migrator.close();
  stdout.writeln(
    result.applied.isEmpty
        ? 'migrations: up to date'
        : 'migrations: applied ${result.applied.join(', ')}',
  );

  final server = await buildApp().serve(Env.boot, port: port, isolates: 1);
  stdout.writeln('keta_files_example listening on :$port');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
