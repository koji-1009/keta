import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/routes.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<void> main() async {
  // Same lifecycle as the register-based example: migrate once before serve.
  final migrator = SqliteDb.open('app.db');
  final result = await applyMigrations(migrator, directory: 'migrations');
  await migrator.close();
  stdout.writeln(
    result.applied.isEmpty
        ? 'migrations: up to date'
        : 'migrations: applied ${result.applied.join(', ')}',
  );

  final server = await buildApp().serve(Env.boot, port: 8080, isolates: 1);
  stdout.writeln('keta_files_example listening on :8080');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
