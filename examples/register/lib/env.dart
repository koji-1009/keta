import 'dart:io';
import 'dart:isolate';

import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_rds/keta_rds.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

/// The application environment: the constructor graph that carries the app's
/// dependencies. keta reaches [log] and [close] structurally; keta_db reaches
/// [db].
///
/// [bus] is the fan-out seam `/users/events` streams from and the write
/// handlers publish to (see lib/events.dart) — Env-owned and closed on
/// shutdown, the same lifecycle discipline keta_otel's exporter uses. Which
/// [Bus] implementation it holds depends on how this isolate was booted: see
/// [boot] and [connectBus].
///
/// [rds] is NOT this example's datastore — that stays SQLite via [db], same as
/// ever. It is an optional, separate connection pool to PostgreSQL, wired only
/// when `KETA_RDS_URL` is set, and it exists solely so `/ready` has a real
/// [RdsDb.poolStats] to read. See lib/readiness.dart and the README's
/// "Readiness" section for why this example carries a second, unused-for-data
/// database handle.
class Env implements HasLog, HasDb, Disposable {
  Env(this.db, this.log, this.bus, {this.rds});
  @override
  final Db db;
  @override
  final Log log;
  final Bus bus;
  final RdsDb? rds;

  /// Boots a single-isolate [Env]: the [InMemoryBus] seam, for `serve()` at
  /// its default `isolates: 1`. See [connectBus] for the multi-isolate path.
  static Future<Env> boot() => _boot(InMemoryBus());

  /// Boots an [Env] whose bus is a connection to the [IsolateBus] hub reached
  /// through [busPort] — the shape every worker isolate of `serve(isolates:
  /// n)` needs (see bin/main.dart). The SAME closure this produces also runs
  /// on isolate 0 (the isolate `serve` was called from): `serve` invokes
  /// `boot` identically in every isolate it owns, so isolate 0 is a
  /// connection too, not a special case — only the hub itself, created once
  /// in bin/main.dart before `serve` is ever called, is not.
  static Future<Env> connectBus(SendPort busPort) =>
      _boot(IsolateBus.connect(busPort));

  static Future<Env> _boot(Bus bus) async {
    final db = SqliteDb.open(Platform.environment['KETA_DB_PATH'] ?? 'app.db');
    // Read-only guard: if the schema is behind, fail loudly here instead of as
    // per-request 500s. main applies migrations before serve; this catches a
    // server started against an unmigrated database.
    await db.verifyMigrations('migrations');
    final rdsUrl = Platform.environment['KETA_RDS_URL'];
    return Env(
      db,
      StdoutLog(),
      bus,
      rds: rdsUrl == null ? null : RdsDb.url(rdsUrl),
    );
  }

  @override
  Future<void> close() async {
    await bus.close();
    final r = rds;
    if (r != null) await r.close();
    await db.close();
  }
}
