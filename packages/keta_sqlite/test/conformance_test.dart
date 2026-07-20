/// keta_db's shared adapter conformance suite, run against SQLite.
///
/// The floor every `Db` owes its callers is written once, in keta_db, and both
/// adapters run it — so a check nobody thought to write on this side (this
/// suite's boolean tests are the example: SQLite has no boolean, and a
/// SQLite-only reading of the contract never produced one) is structurally
/// present rather than a matter of who remembered.
///
/// The DDL types are this engine's spelling: SQL dialect is deliberately
/// outside keta's scope, and `decimalType: 'text'` is the documented way to
/// hold an exact decimal on an engine whose NUMERIC affinity would discard
/// digits. The suite separately proves that a NUMERIC column here does lose
/// them, so `capabilities.exactDecimal: false` is pinned to observed behaviour
/// rather than asserted in prose.
library;

import 'package:keta_db/test.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

void main() {
  runDbConformance(
    open: () async => SqliteDb.memory(),
    boolType: 'integer',
    decimalType: 'text',
    timestampType: 'text',
  );
}
