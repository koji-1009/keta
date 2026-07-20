# keta_sqlite

A thin adapter over the `package:sqlite3` family: `SqliteDb` implements keta_db's `Db` contract on a single embedded SQLite connection, on-disk or `:memory:`. It is Ring 2 — it depends on `keta` (for the exception vocabulary), `keta_db` (for the contract), and `sqlite3` (for the engine), and nothing else.

Provisional: the native `libsqlite3` is taken from the system. Until a source-pinned build hook bundles it, a `dart compile exe` binary is not self-contained on a distroless/scratch image.

## Opening a database

```dart
import 'package:keta_sqlite/keta_sqlite.dart';

final db = SqliteDb.open('app.db');          // creates the file if absent
final mem = SqliteDb.memory();               // a private in-memory database
final walDb = SqliteDb.open('app.db', wal: true, lockTimeout: Duration(seconds: 5));
```

Every connection opens under the same PRAGMA contract. `foreign_keys = ON`: sqlite3 defaults this OFF for pre-3.6.19 compatibility, and without it a migration that declares `FOREIGN KEY` constraints gets silent non-enforcement — a schema documenting an invariant nothing checks. `busy_timeout = lockTimeout`: a second connection on the same file (another process or isolate) waits no longer for the lock than a same-process caller does before getting a loud, bounded failure.

`wal: true` (opt-in, default off) switches a file-backed database to WAL journaling, so readers and the single writer stop blocking each other — across processes, not just within this isolate. The switch is verified: `PRAGMA journal_mode = WAL` reports the mode actually in force, so if the filesystem cannot host WAL's `-wal`/`-shm` shared-memory index (NFS cannot), `open` throws a `StateError` at startup rather than running under a false belief. On `memory()`, `wal` is a deliberate no-op: an in-memory database has no file for the sidecar index and sqlite3 will not switch it, so `memory(wal: true)` simply opens a normal in-memory database.

## The `Db` contract on a single-writer engine

`reader` and `writer` are the same connection — SQLite is single-writer, and `Db` deliberately declares no pool-stats surface a single-connection adapter could only fabricate (see keta_db's `Db` doc). `query` returns rows as column-name maps; `execute` returns the changed-row count.

The type contract: `INTEGER` → `int`, `REAL` → `double`, `TEXT` → `String`, `BLOB` → fixed-length `List<int>`, `NULL` → `null`. SQLite has no native decimal type — a `decimal`/`numeric` column has NUMERIC affinity, so the same column can come back as `int` (for `5.0`) or `double` (for `5.5`), never an exact decimal string. Store exact decimals (money) as TEXT if you need them preserved. A duplicate column name (`SELECT 1 AS x, 2 AS x`) resolves to its last occurrence, matching sqlite3's own `Row` semantics.

## Transactions

```dart
await db.transaction((conn) async {
  final rows = await conn.query('select balance from accounts where id = ?', [id]);
  await conn.execute('update accounts set balance = ? where id = ?', [next, id]);
});
```

A normal return commits; a thrown error rolls back and rethrows, and a failing `ROLLBACK` never masks the original error. Transactions do not nest — an inner `transaction` call is a `StateError`.

Every transaction opens with `BEGIN IMMEDIATE`, not the deferred default. A deferred read-then-write body asks to upgrade a read lock to a write lock, and SQLite returns `SQLITE_BUSY` *immediately* on that upgrade, bypassing `busy_timeout` entirely. Taking the write lock at `BEGIN` — where `busy_timeout` does apply — turns cross-connection contention into a bounded wait and a loud, timed `Unavailable` instead of a surprise busy on the first `UPDATE`. The consequence worth naming: a transaction used purely for a consistent multi-statement read still takes the write lock and serializes behind every writer, even under WAL.

Inside the callback, use the `conn` handed in. A `writer`/`reader` call made from within the callback happens to join the open transaction here (same connection, no re-lock) — but that is a single-writer accident, not the portable contract: on keta_rds the same call runs on a separate pooled connection outside the transaction. keta_db's `tx()` middleware works unchanged over this adapter — register it inside `recover()` (`app..use(recover())..use(tx())`) and read the connection via `c.get(txConn)`.

## Concurrency model

One connection, serialized through an async lock: a `query`/`execute` takes the lock for its call, and a `transaction` holds it across the whole `BEGIN`..`COMMIT`/`ROLLBACK`, spanning every await inside the callback. Concurrent requests are correct by serialization — no interleaving into an open transaction, no spurious nesting error, no lost updates. A caller that cannot acquire the lock within `lockTimeout` (default 30s) fails with `Unavailable` (503) rather than deadlocking silently, and `close()` waits for an in-flight transaction rather than killing it.

Stated constraint: sqlite3 calls are synchronous FFI on the serving isolate, so a slow query blocks that isolate's entire event loop — and `busy_timeout`'s retry loop spins *inside* that synchronous call, so a cross-process writer contending for the file lock blocks the whole isolate for up to `lockTimeout`. This is a property of embedding SQLite in-process, not a bug; the mitigations are `serve(isolates: n)`, keeping queries indexed and small, and keeping `lockTimeout` modest where cross-process writers are expected.

## Error translation

The `Db` contract is driver-agnostic, so the driver's vocabulary stops here — a handler never imports `package:sqlite3` to find out what went wrong:

- A uniqueness violation — `SQLITE_CONSTRAINT_PRIMARYKEY`, `SQLITE_CONSTRAINT_UNIQUE`, or `SQLITE_CONSTRAINT_ROWID` — becomes keta's `Conflict` (409). The driver's message, which names the colliding table and column, is carried as `detail`: `recover()` logs it, and `KetaException.toString()` keeps it out of the response.
- `SQLITE_BUSY` — a *different* connection (another process, or another isolate on the same file) held the lock past `busy_timeout` — becomes `Unavailable` (503), the same condition the in-process lock timeout reports.
- Deliberately not every `SQLITE_CONSTRAINT`: a NOT NULL, CHECK, FOREIGN KEY, or TRIGGER violation is the app's own data being wrong. That is a bug, and the 500 it already earns is the honest answer — a 409 would tell the client to retry something that can never succeed. (This matches keta_db's floor: SQLite, single-writer, has no serialization failure or deadlock to translate, so the SQLSTATE-tier mappings do not apply.)

Translation covers the whole `BEGIN`..`COMMIT` span, not just the statements inside the callback: a cross-connection lock timeout at `BEGIN IMMEDIATE` — exactly where this adapter takes the write lock, so exactly where a contending writer surfaces — arrives as the promised `Unavailable`, not a raw `SqliteException`. The `ROLLBACK` on the error path is the one statement left untranslated, on purpose: its outcome is swallowed either way, and the original error is what rethrows.

## Migrations

The adapter runs keta_db's migration tools directly. `dart run keta_sqlite:migrate` applies pending `migrations/*.sql` files (named `NNNN_name.sql`, ascending) to the database named by `KETA_DB` (`sqlite:app.db` or `sqlite::memory:`), each migration and its `_keta_migrations` ledger row committing together — including multi-statement migrations with triggers, whose parsing is delegated to the driver. It is single-applier by contract: run it once, before the fleet boots. Each node/isolate then calls `db.verifyMigrations()` at boot — read-only, safe everywhere — which fails loudly on unapplied versions and on checksum drift (an already-applied file edited after the fact).

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| `foreign_keys = ON` on every connection; a FK violation is rejected — and stays a raw `SqliteException`, not a translated `Conflict` | `test/pragma_test.dart` |
| WAL opt-in: `wal: true` reports `journal_mode` wal, the default stays on the rollback journal, `memory(wal: true)` still opens a working in-memory db | `test/pragma_test.dart` |
| cross-connection `SQLITE_BUSY` → `Unavailable`, both on a statement and when `transaction()`'s `BEGIN IMMEDIATE` itself is blocked | `test/pragma_test.dart` |
| duplicate primary key and duplicate unique index → `Conflict`, inside a transaction too; the collision detail is carried but not shown to the client; a non-uniqueness constraint is left alone | `test/conflict_test.dart` |
| commit on return, rollback on throw; a failing `ROLLBACK` does not mask the original error; uniqueness surfaces as `Conflict` and everything else raw | `test/sqlite_contract_test.dart` |
| the type contract round-trips: changed-row counts, empty result sets, `NULL` as present-`null`, fixed-length BLOBs, duplicate-column last-wins, fractional numerics as `double` | `test/sqlite_contract_test.dart` |
| the lock serializes actions, the active transaction zone does not re-lock, a captured zone cannot bypass the lock to dirty-read, a hung transaction 503s waiters instead of deadlocking, `close` waits for an in-flight transaction and is idempotent, `open` persists across close/reopen | `test/sqlite_contract_test.dart` |
| concurrent transactions serialize with no nesting error and no lost updates; a plain write does not interleave into an open transaction; a genuinely nested transaction is a `StateError` | `test/concurrency_test.dart` |
| keta_db's `tx()` middleware commits/rolls back over this adapter | `test/tx_middleware_test.dart` |
| migrations apply in order, record, and stay idempotent; triggers (multi-statement) apply; verify catches a never-migrated db, an edited applied file, and passes once current; a pre-checksum ledger is upgraded in place; out-of-order pending versions are a hard error | `test/migration_engine_test.dart` |
| a failed migration names its version and constraint | `test/migration_failure_test.dart` |
