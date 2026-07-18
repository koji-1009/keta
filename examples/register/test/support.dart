/// Shared scaffolding for the register example's suite: an in-memory [Env]
/// booted from the real migrations, and the demo bearer tokens every route
/// that is not explicitly public expects. Not itself a `_test.dart` file, so
/// `dart test` does not run it — only the suites that import it do.
library;

import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_register_example/env.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

Future<Env> bootTestEnv() async {
  // Build the schema from the same migrations the server runs, so the migration
  // files are the single source of truth and are exercised by the suite.
  final db = SqliteDb.memory();
  await applyMigrations(db, directory: 'migrations');
  // A fresh InMemoryBus per env, same reason the db is fresh per env: two
  // tests (or two envs in one test) must not cross-talk on either seam. `rds`
  // is left null — no test here needs a live Postgres; see
  // test/readiness_test.dart for the RdsPoolStats-driven policy, tested
  // directly with no connection required.
  return Env(db, StdoutLog(flushInterval: Duration.zero), InMemoryBus());
}

/// Every request that is not explicitly public needs credentials — the app is
/// secure by default. These mirror lib/auth.dart's demo tokens.
const admin = {'authorization': 'Bearer t-admin'};
const user = {'authorization': 'Bearer t-user'};
