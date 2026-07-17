# keta_rds

A PostgreSQL [`Db`](../keta_db) adapter for keta. It delegates the wire protocol to [package:postgres](https://pub.dev/packages/postgres) — keta writes no bytes of its own — and owns exactly three things: a bounded connection pool behind `reader`/`writer`, the translation of the driver's errors into keta's sealed exceptions, and the §3 type-mapping contract on the rows that come back.

## Connecting

```dart
// From a URL (what KETA_DB carries; sslmode etc. ride as query params):
final db = RdsDb.url('postgres://user:pass@host:5432/app?sslmode=disable');

// Or from an endpoint, with an optional read replica:
final db = RdsDb(
  Endpoint(host: 'primary', database: 'app', username: 'u', password: 'p'),
  readerEndpoint: Endpoint(host: 'replica', database: 'app', username: 'u', password: 'p'),
  settings: const ConnectionSettings(sslMode: SslMode.require),
);
```

`reader` and `writer` share one pool aimed at the primary unless a reader endpoint is given, in which case reads go to a second pool aimed at the replica.

## The pool model

Each `query`/`execute` checks out a connection for that one call and returns it immediately; `transaction(f)` pins one connection from the writer pool for its whole `BEGIN`..`COMMIT`/`ROLLBACK` span. At most `maxConnections` connections are ever live per pool (default 10). Opening is lazy and idle connections are reused. A checkout that cannot be satisfied within `acquireTimeout` (default 30s) fails with `Unavailable` (503) rather than blocking forever — a saturated pool is transient overload, not a deadlock.

Pool ceilings are **per isolate and per pool**. Behind a proxy such as RDS Proxy, keep them small, and size the sum across isolates against the server's connection limit.

**Disconnect recovery.** A connection the driver tears down mid-session (a dead socket, a server-initiated shutdown) is never handed back to the pool — it is disposed, and the next `acquire` opens a fresh one. Retrying the in-flight query itself is deliberately absent: whether it was safe to run again is unknowable at this layer (a caller wanting that must make its own query idempotent and retry above `Db`).

## Placeholders

SQL uses `?` positional placeholders, exactly as in keta_sqlite, so the same statement runs on either engine — the driver desugars them to PostgreSQL's `$1` form. A parameterless statement is sent via the simple query protocol, which is what lets a migration file carry several `;`-separated statements in one `execute`.

`?` inside a string literal, a `$$`-quoted (dollar-quoted) string, or a comment is safe — the driver's tokenizer skips those spans entirely before it ever looks for a placeholder. Outside them it is not: a *parameterized* statement (one with params to bind) that also uses one of PostgreSQL's own `?`-family jsonb operators (`?`, `?|`, `?&` — e.g. `data ? 'key'`) will have that operator's `?` mistaken for a placeholder and desugared out from under it. A parameterless statement never hits the tokenizer, so it is unaffected. When a query needs both bound parameters and one of these operators, either avoid mixing them in the same statement, or use the equivalent jsonb functions instead of the operators (`jsonb_exists`, `jsonb_exists_any`, `jsonb_exists_all` for `?`, `?|`, `?&` respectively).

## Error-translation floor

The adapter translates only the conditions a caller can act on into keta's vocabulary, so a handler never imports package:postgres to learn what went wrong and does not break when pointed at another engine:

| Condition | SQLSTATE / source | keta exception |
|---|---|---|
| uniqueness violation | `23505` | `Conflict` (409) — the driver's constraint/detail carried in `detail`, withheld from the client |
| lock unobtainable in time | `55P03` | `Unavailable` (503) |
| server refusing new work or tearing down the session | `53300`, `57P03`, `57P01`, `57P02` | `Unavailable` (503) |
| server unreachable / connection lost mid-session / pool-acquire timeout | socket error, connection-fatal `PgException`, the socket dying mid-session, pool timeout | `Unavailable` (503) |

Everything else passes through exactly as the driver threw it. A NOT NULL, CHECK, or FOREIGN KEY violation is the app's own bug: it earns the 500 it gets, and a 409 would only tell the client to retry the unretryable. This is a floor — an adapter may translate more, never less.

## Type contract

Rows come back as column-name maps. `integer` → `int`, `double precision` → `double`, `boolean` → `bool`, `null` → `null` with the key present, and `numeric`/`decimal` → `String` (precision preserved — this adapter is the first that can fully honour that clause). `bytea` → a fixed-length `List<int>`. Values outside the contract (json/jsonb, arrays, geometric types) pass through as the driver decoded them.

**Temporal types render by column type, not one blanket rule.** The driver decodes `date`, `timestamp`, and `timestamptz` all to the same UTC-tagged `DateTime`, so a single `toIso8601String()` would be wrong for two of them. keta renders each honestly instead:

| Column type | Example output | Rule |
|---|---|---|
| `timestamptz` | `2026-07-17T10:30:00.000Z` | a real instant, emitted as UTC with a `Z` |
| `timestamp` (no time zone) | `2026-07-17T10:30:00.000` | a wall-clock reading with **no offset designator** |
| `date` | `2026-07-17` | a calendar day, `yyyy-MM-dd`, no time-of-day |

The bare `timestamp` case is deliberate: a `timestamp without time zone` column genuinely does not know its zone, so keta refuses to stamp a `Z`/`+00:00` the value never carried — the ambiguity belongs to the column type, not to keta. **If you need an unambiguous instant, use `timestamptz`.** A `timestamp` string is a wall clock whose zone only the writer knows.

## Migrations

```bash
export KETA_DB='postgres://user:pass@host:5432/app'
dart run keta_rds:migrate            # applies migrations/*.sql in numeric order
dart run keta_rds:migrate ./schema   # override the directory
```

The runner lives in keta_db; the bin ships here because a pure keta_db bin cannot open a Postgres connection without a ring cycle. Files are `NNNN_name.sql`, applied in ascending numeric order, each recorded in `_keta_migrations` so it runs at most once. No down files — fixes go forward.

### The single-applier rule

`applyMigrations` assumes **exactly one concurrent applier** and ships no advisory-lock arbitration. A multi-node deployment serializes application externally — a CI/CD step, an init container, or a dedicated job runs the migrate bin **once, before any server isolate is spawned**. What runs per node/isolate at boot is the read-only `db.verifyMigrations(dir)`, which never writes (so N concurrent runs are safe) and fails loudly if the schema is behind. Should two appliers race anyway, the `_keta_migrations` primary key plus PostgreSQL's transactional DDL turns the collision into a loud failure, not silent corruption.

## Tests

Unit tests (pool checkout/exhaustion, error translation, URL parsing) run with no server. The contract suite in `test/rds_contract_test.dart` runs against a real database only when `KETA_TEST_PG` names one (a `postgres://` URL); absent that, it is reported as **skipped**, never as a silent pass.
