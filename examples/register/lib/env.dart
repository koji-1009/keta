import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

/// The application environment: the constructor graph that carries the app's
/// dependencies. keta reaches [log] and [close] structurally; keta_db reaches
/// [db].
class Env implements HasLog, HasDb, Disposable {
  Env(this.db, this.log);
  @override
  final Db db;
  @override
  final Log log;

  /// The database path comes from the environment (§9: env vars only, no config
  /// files at runtime), defaulting to `app.db`.
  static Future<Env> boot() async {
    final db = SqliteDb.open(Platform.environment['KETA_DB_PATH'] ?? 'app.db');
    // Read-only guard: if the schema is behind, fail loudly here instead of as
    // per-request 500s. main applies migrations before serve; this catches a
    // server started against an unmigrated database.
    await db.verifyMigrations('migrations');
    return Env(db, StdoutLog());
  }

  @override
  Future<void> close() => db.close();
}
