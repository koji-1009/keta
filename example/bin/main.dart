import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_example/app.dart';
import 'package:keta_example/env.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<void> main() async {
  // Migrate once here, before any isolate boots: Env.boot runs per isolate, so
  // applying migrations there would race N connections onto the same file. A
  // single throwaway connection brings the schema up to date first.
  final migrator = SqliteDb.open('app.db');
  final result = await applyMigrations(migrator, directory: 'migrations');
  await migrator.close();
  stdout.writeln(
    result.applied.isEmpty
        ? 'migrations: up to date'
        : 'migrations: applied ${result.applied.join(', ')}',
  );

  // serve boots one env per isolate; Env.boot is a static tear-off, so the same
  // call scales horizontally by raising `isolates`.
  final server = await buildApp().serve(Env.boot, port: 8080, isolates: 1);
  stdout.writeln('keta_example listening on :8080');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
