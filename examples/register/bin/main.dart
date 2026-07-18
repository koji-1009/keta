import 'dart:io';

import 'package:keta_bus/keta_bus.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_register_example/app.dart';
import 'package:keta_register_example/env.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<void> main() async {
  // Configuration from the environment only (§9): DB path, port, and worker
  // count, with sensible defaults. No config files are read at runtime.
  final dbPath = Platform.environment['KETA_DB_PATH'] ?? 'app.db';
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final isolates =
      int.tryParse(Platform.environment['KETA_ISOLATES'] ?? '') ?? 1;

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

  // The bus wiring depends on how many isolates will serve requests. With one
  // isolate there is nothing to fan out across, so `Env.boot` picks the
  // simplest seam, an InMemoryBus. With more than one, every isolate
  // `serve(isolates: n)` owns — including isolate 0, the one this `main` runs
  // on — needs to reach the SAME bus, which is what IsolateBus is for: this
  // isolate creates the hub and captures its connectPort (a SendPort, and
  // therefore the one piece of hub state that can actually cross into a
  // spawned isolate), and `Env.connectBus` — the boot closure handed to
  // `serve` — attaches every isolate to it via `IsolateBus.connect`. See
  // lib/env.dart's `boot`/`connectBus` doc for the isolate-0-is-not-special
  // detail this depends on.
  final IsolateBus? hub;
  final Future<Env> Function() boot;
  if (isolates > 1) {
    final h = IsolateBus.hub();
    hub = h;
    final busPort = h.connectPort;
    boot = () => Env.connectBus(busPort);
  } else {
    hub = null;
    boot = Env.boot;
  }

  // serve boots one env per isolate via `boot`; the same closure scales
  // horizontally by raising `isolates`.
  final server = await buildApp().serve(boot, port: port, isolates: isolates);
  stdout.writeln(
    'keta_register_example listening on :$port (isolates: $isolates)',
  );
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
  // The hub outlives every isolate's own Env (each Env closes its own bus
  // CONNECTION in Env.close via Server.shutdown's Disposable call — see
  // lib/env.dart) but the hub itself belongs to no isolate's Env, since it was
  // created here, before any of them booted. Closing it after shutdown tells
  // any connection that somehow missed its own close (there should be none,
  // in an orderly shutdown) to terminate too.
  await hub?.close();
}
