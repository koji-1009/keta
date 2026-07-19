# keta_db

The Ring 1 pillar under keta's database story: the `Db` abstraction (`reader`/`writer`), the `tx()` transaction vessel, the `HasDb` environment contract, and the migration runner. keta_db is driver-agnostic — it never opens a socket or a file itself; concrete engines live in adapter packages (`keta_sqlite` over the `package:sqlite3` family, `keta_rds` over PostgreSQL via `package:postgres`), and code written against `Db`/`DbConn` runs unchanged on either.

## The `Db` abstraction: one reader, one writer

A `Db` is two connections and a transaction. `reader` and `writer` are `DbConn`s — the same connection on a single-writer engine like SQLite, distinct on an engine that can route reads elsewhere — and a `DbConn` has exactly two methods: `query(sql, [params])` returns rows as column-name maps (`Future<List<Map<String, Object?>>>`), and `execute(sql, [params])` returns the number of rows changed. That count is meaningful only for `INSERT`/`UPDATE`/`DELETE`; for DDL or a `SELECT` the value carries over from the last DML, so don't branch on it there.

**No shared pool/connection-stats surface** (a judged absence, documented on `Db`): what a connection accessor can honestly report is adapter-specific — keta_rds genuinely runs a bounded pool and reports it as `RdsDb.poolStats`, while a single-connection adapter has no pool to describe — so `Db` declares no `poolStats`-shaped member; look for a stats accessor on the concrete adapter type.

## Errors are keta's, not the engine's

An adapter translates the conditions a caller can act on into keta's sealed `KetaException` family, so a handler never imports a driver package to find out what went wrong. The floor every adapter must honour on every engine: a uniqueness violation → `Conflict`; the database unreachable, or its lock unobtainable in time → `Unavailable`. Adapters over an engine that classifies errors by SQLSTATE (the PostgreSQL family) must additionally translate a foreign-key violation → `Conflict`, a NOT NULL or CHECK violation → `UnprocessableEntity`, and a serialization failure or deadlock → `TransientFailure` — a tier scoped to SQLSTATE-classed engines on purpose, because a single-writer engine like SQLite has no serialization failure or deadlock to translate at all. Anything else is the app's own bug and is left as the driver threw it, where the 500 and its log are the honest answer. This is a floor, not a ceiling: an adapter may translate more, never less.

## The transaction vessel

`Db.transaction(f)` runs `f` in a transaction: a normal return commits, a thrown error rolls back and rethrows. Transactions do not nest — an inner call is a `StateError`. Inside `f`, go through the `DbConn` you were handed: reaching back to `reader`/`writer` from inside a transaction is not portable (on keta_sqlite the call joins the open transaction; on keta_rds it acquires a separate pooled connection running autocommit outside it, and can even self-starve against the connection `f` already holds). On a single-writer engine the lock is held across every await inside `f`, so keep transactions short and DB-bound — never await unbounded external work inside one.

### `tx()` — the transaction as middleware

`tx<E extends HasDb>()` wraps the downstream handler in `env.db.transaction`, publishing the transaction connection under the `txConn` key: the handler returning normally commits, a thrown error rolls back and propagates. It must be the **innermost** middleware — registered after (inside of) `recover()`, as `app..use(recover())..use(tx())` — because with the order reversed, `recover()` converts a thrown error into an ordinary `Response` before it reaches `tx()`, and the transaction commits the writes of a request that actually failed. `tx()` wraps every request it covers, reads included, each pinning a **writer** connection for its whole duration — so don't mount it app-wide; scope it to the routes that actually write:

```dart
app
  ..use(recover())
  ..get('/things', listThings);                // reads: no tx(), free to use env.db.reader

final things = app.group('/things')..use(tx()); // only the write group pays for a transaction
things.post('/', (c) async {
  await c.get(txConn).execute('insert into things (name) values (?)', ['a']);
  return c.json({'ok': true}, status: 201);
});
```

The value published under `txConn` is a completion guard, never the raw adapter connection: the instant the handler returns (or throws), the transaction ends and any later `query`/`execute` on that connection — a streaming response body running after the handler returned, a closure that outlived the request — throws `StateError('transaction already completed')` instead of running on a session already committed and returned to the pool. The guard only rejects calls made *after* completion; a query already in flight when the handler returns keeps running — an unawaited query left racing COMMIT/ROLLBACK is the caller's own race, not something the guard closes.

## The `Env` contract

`HasDb` is one getter — `Db get db` — and it is how `tx()` and the migration tools reach the database without the framework learning DB vocabulary. keta's `serve(boot, ...)` runs `boot` once per isolate, so every isolate owns its own env (and its own `Db`); implement keta's `Disposable` and `Server.shutdown()` calls `close()` after draining in-flight requests. The boot is where the read-only migration check belongs:

```dart
class Env implements HasDb, Disposable {
  Env(this.db);
  @override
  final Db db;
  @override
  Future<void> close() => db.close();
}

Future<Env> boot() async {
  final db = SqliteDb.open('app.db');       // the keta_sqlite adapter
  await db.verifyMigrations('migrations');  // fail loudly at boot, not as per-request 500s
  return Env(db);
}
```

## The migration runner

A migration is a file: `NNNN_name.sql`, identified by its numeric version prefix and applied in ascending numeric order — the name half is documentation for humans; the ledger keys on version and checksum alone. `loadMigrations(directory)` reads and validates them: a missing directory is a `FileSystemException` (usually a typo or wrong cwd), and a malformed name, a non-numeric version, an empty (or whitespace-only) file, or a duplicate numeric version — `0001` and `1` collide — is a `FormatException`.

`applyMigrations(db, {directory = 'migrations', allowOutOfOrder = false})` applies the pending ones, recording each in the `_keta_migrations` table so it runs at most once. Each migration body and its ledger row commit in one transaction, so a failure leaves the schema exactly at the last fully-applied version — and there is no rollback path: fixes go forward. The ledger row carries an FNV-1a 64 checksum of the file's raw bytes (deliberately not a cryptographic hash — this detects *accidental* drift, not tampering, and keta_db carries no crypto dependency); a pre-checksum ledger is upgraded in place with `ALTER TABLE`, its old rows keeping a NULL checksum that verify accepts. A pending version below the highest already-applied one is a hard error by default (two branches merged in an order nobody tested); pass `allowOutOfOrder: true` for a deliberate backfill. **Single-applier contract**: the function takes no advisory lock and arbitrates nothing between concurrent callers — multi-node deployments serialize application externally (a CI/CD step, an init container), and the adapters ship it as a CLI (`dart run keta_sqlite:migrate`, `dart run keta_rds:migrate`).

`db.verifyMigrations([directory = 'migrations'])` is the other half of the division of labour: a read-only check, safe for every node and isolate to run concurrently at boot, that throws a `StateError` naming the unapplied versions — or the versions whose on-disk file no longer matches the checksum the ledger recorded, catching an already-applied migration edited after the fact. Basic connectivity is probed before the ledger is consulted, so an unreachable database surfaces as its own error rather than a misleading "unapplied migrations". Both apply and verify route every ledger read through `Db.writer`, never `reader`: right after a deploy's migration step, a lagging read replica would report the freshly-written ledger rows as still pending.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| in-transaction `query`/`execute` through `txConn` reach the connection untouched | `test/tx_test.dart` |
| after COMMIT (normal return) the guard throws `StateError('transaction already completed')`, and the call never reaches the connection | `test/tx_test.dart` |
| after ROLLBACK (handler throw, error propagated) the guard trips the same way | `test/tx_test.dart` |
| filename parsing (`NNNN_name.sql`), numeric — not lexical — sort, non-`.sql` files ignored | `test/load_migrations_test.dart` |
| missing directory → `FileSystemException`; malformed name, non-numeric version, empty file, duplicate numeric version (padding included) → `FormatException` | `test/load_migrations_test.dart` |
| applies in version order, recording a UTC ISO-8601 `applied_at` and a 16-hex FNV checksum per row | `test/apply_migrations_test.dart` |
| idempotent across runs; only newly-added migrations apply; a renamed version (padding changed) does not re-apply | `test/apply_migrations_test.dart` |
| a failing migration commits neither its body nor its ledger row; a failing ledger insert rolls back the body too; clearing the failure lets it apply (forward fix) | `test/apply_migrations_test.dart` |
| out-of-order pending version is a hard error naming offender and barrier; `allowOutOfOrder: true` applies it deliberately | `test/apply_migrations_test.dart` |
| a legacy ledger is upgraded with `ALTER TABLE`, old rows keeping NULL checksums | `test/apply_migrations_test.dart` |
| a raw (untranslated) SQL error names the failing migration version | `test/apply_migrations_test.dart` |
| verify passes when current, names every pending version (and the migrate command), reports only the missing ones on a partial schema | `test/verify_migrations_test.dart` |
| an edited already-applied file fails verify naming the version; a legacy NULL checksum is accepted | `test/verify_migrations_test.dart` |
| an unreachable database surfaces its own error, not a pending-migrations `StateError` | `test/verify_migrations_test.dart` |
| apply and verify route every ledger read through the writer, never the reader | `test/apply_migrations_test.dart`, `test/verify_migrations_test.dart` |
