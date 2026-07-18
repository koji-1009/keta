# keta_register_example

A runnable keta app: a small user API over SQLite, in both routing syntaxes,
with OpenAPI output. It doubles as the reference the file-convention example
(`../files`) is checked against. For authentication, see
`../auth`.

## Run

```bash
dart run bin/main.dart
```

`main` applies any pending migrations from `migrations/` once, then serves
(migrations are wired into startup, not run by hand). Stop with SIGTERM for a
graceful shutdown. For a watch-and-restart dev loop: `dart run tool/dev.dart`.

Configuration is environment-only (§9): `KETA_DB_PATH` (default `app.db`),
`PORT` (default `8080`), `KETA_ISOLATES` (default `1` — see "The SSE feed
runs on a bus" below for what changes above 1), and `KETA_RDS_URL` (unset by
default — see "Readiness" below).

The middleware stack (`lib/app.dart`, `buildApp`) shows the common cross-cutting concerns, in registration order: `accessLog`, `cors`, `recover`, `timeout`, request metrics (`otel`), `enforceSecurity`, and a `tx` per request. The order is load-bearing, not decoration — see the comment on `buildApp` for why (everything that can throw sits below `recover`; everything that decorates a response sits above it).

## Endpoints

| Method | Path                       | Description                          |
|--------|----------------------------|--------------------------------------|
| GET    | `/health`                  | Liveness check                       |
| GET    | `/ready`                   | Readiness probe (`RdsDb.poolStats`-backed, when configured) |
| GET    | `/users`                   | List users (`?limit`, `?role`); nested `UserList` |
| GET    | `/users/by-role/:role`     | List users of one role (typed `Role` capture) |
| GET    | `/users/events`            | Live feed of create/update/delete (SSE) |
| POST   | `/users`                   | Create a user (validated; 201 + Location) |
| GET    | `/users/:id`               | Fetch a user                         |
| PUT    | `/users/:id`               | Replace a user (404 if absent)       |
| DELETE | `/users/:id`               | Delete a user (204; 404 if absent)   |
| GET    | `/users/:uid/tags/:index`  | Read one tag by index                |
| GET    | `/whoami`                  | The authenticated caller             |
| GET    | `/admin/ping`              | Admin-only liveness check (403 if not admin) |
| POST   | `/uploads`                 | multipart/form-data upload (keta_multipart) |
| GET    | `/metrics`                 | Prometheus-format request metrics    |

Every route above defaults to `apiDefaults = [bearer]` (`lib/auth.dart`) unless it declares otherwise — `/health` is explicitly public (`security: []`), and `/metrics` requires `apiKey` instead of bearer. That default is secure-by-default: forgetting to declare a route's security fails closed, not open. `lib/auth.dart` ships two demo bearer tokens (`t-admin`, resolving to an admin principal; `t-user`, a non-admin) and one demo API key (`k-metrics`) — a real app swaps the in-memory `_tokens`/`_apiKeys` tables for a JWT or session check without touching anything else.

```bash
curl -sX POST localhost:8080/users -H 'content-type: application/json' -H 'authorization: Bearer t-admin' \
  -d '{"id":"1","name":"Ada","role":"admin","tags":["x","y"]}'
curl -s 'localhost:8080/users?role=admin&limit=10' -H 'authorization: Bearer t-admin'
curl -sX PUT localhost:8080/users/1 -H 'content-type: application/json' -H 'authorization: Bearer t-admin' \
  -d '{"id":"1","name":"Ada B","role":"member","tags":[]}'
curl -sX DELETE localhost:8080/users/1 -H 'authorization: Bearer t-admin' -o /dev/null -w '%{http_code}\n'
curl -s localhost:8080/metrics -H 'x-api-key: k-metrics'
```

## The SSE feed runs on a bus, and can fan out across isolates

`/users/events` used to stream from an in-process `StreamController.broadcast()`
scoped to one `buildApp()` call — which only ever reached subscribers in the
SAME isolate. `serve(isolates: n)` runs request handlers across worker
isolates, so a write landing on one isolate never reached a subscriber parked
on another. `lib/events.dart` now streams from `c.env.bus` instead (a
[`keta_bus`](../../packages/keta_bus) `Bus`, Env-owned and closed on
shutdown — see `lib/env.dart`): the write handlers `publish` to the `users`
topic and `/users/events` `subscribe`s to it, and the same `publish`/
`subscribe` calls work unchanged whether the bus is single-isolate or not.

Which `Bus` implementation a run gets depends on `KETA_ISOLATES`
(`bin/main.dart`):

- **`KETA_ISOLATES` unset or `1`** (the default): `Env.boot` wires an
  `InMemoryBus` — the honest choice for one isolate, nothing to fan out
  across.
- **`KETA_ISOLATES` > 1**: `bin/main.dart` creates the `IsolateBus` **hub**
  itself, before `serve` is ever called, and captures its `connectPort` (a
  `SendPort` — the one piece of hub state that can actually cross into a
  spawned isolate). `Env.connectBus(port)` — the `boot` closure handed to
  `serve` — attaches to that hub via `IsolateBus.connect` in EVERY isolate
  `serve` owns, isolate 0 included: `serve` invokes the same `boot` closure
  identically in every isolate it boots, so there is no "this is the main
  isolate" special case to write — only the hub itself, created once outside
  any isolate's `Env`, is not a connection.

```bash
KETA_ISOLATES=3 dart run bin/main.dart   # three isolates, one shared feed
```

`test/bus_wiring_test.dart` proves the multi-isolate fan-out claim at the
level `Env`/`lib/events.dart` actually operate at: it spawns a REAL second
isolate that attaches to a hub via `IsolateBus.connect` (exactly what
`Env.connectBus` does) and publishes a `users` event, and asserts a
subscriber in the test's own isolate receives it through
`userEventsStream`. It does not attempt a full `serve(isolates: n)` test over
real HTTP — which isolate's listener accepts a given connection is an OS/
transport scheduling detail no test can pin, so that version would be flaky
by construction; the test file's own doc comment says exactly what is and
is not covered.

## `tx()` is scoped to the write group, not the whole app

`tx()` (keta_db) pins a **writer**-pool connection for its whole span and
pays a `BEGIN`/`COMMIT` round trip — mounted app-wide, that taxes every read
too, and would have pinned a writer connection for `/users/events`' entire
open-ended SSE lifetime. `lib/routes.dart` scopes it instead to a `/users`
write group:

```dart
final writeUsers = app.group('/users')..use(tx());
writeUsers.on(root).post(...);   // POST /users
writeUsers.put('/:id', ...);     // PUT /users/:id
writeUsers.delete('/:id', ...);  // DELETE /users/:id
```

Every read (`GET /users`, `/users/:id`, `/users/by-role/:role`,
`/users/:uid/tags/:index`, `/users/events`) is registered directly on `app`
and reaches the database through `c.env.db.reader`, never through this
group. `/uploads` writes nothing to the database at all, so it stays off the
group too. See keta_db's `tx()` doc for the full cost accounting this shape
exists to avoid.

## Readiness: an example policy over `RdsDb.poolStats`

**Honesty note:** this example's actual datastore is, and remains, SQLite
(`keta_sqlite`) — nothing here runs against Postgres by default. `/ready` and
`lib/readiness.dart` exist solely to demonstrate `RdsDb.poolStats`
(keta_rds), since no runnable example currently uses `RdsDb` as its real
store; wiring one in wholesale would have meant a second migration dialect
and a live-Postgres dependency for this example's whole test suite, well
past what "a plain route demonstrating the accessor" calls for. Instead,
`lib/env.dart`'s `Env` carries an OPTIONAL `RdsDb? rds`, wired only when
`KETA_RDS_URL` is set (a `postgres://` URL) — every test in this suite, and a
default `dart run bin/main.dart`, leaves it `null`.

`lib/readiness.dart`'s `readinessPolicy(RdsPoolStats)` is a pure function —
not-ready (503) when the writer pool is fully leased AND callers are
queued (`PoolStats.waiting > 0`), degraded (200) past 80% leased with
nobody queued yet, ready otherwise. It is one deliberately simple example
policy, not a prescription; `test/readiness_test.dart` exercises it directly
against constructed `RdsPoolStats` values, no Postgres connection required.
`/ready` itself answers `{"status": "ready", ...}` when `rds` is null (every
test env, and the default run) — `test/readiness_test.dart` covers that
fallback too.

## OpenAPI

```bash
dart run tool/openapi.dart > openapi.yaml
```

The document is a shadow of the code (routes-as-values → OpenAPI 3.1); it is
never a source that drives the code.

## When you add a field

A DTO's `fromJson`, `toJson`, and `Schema` constant are three hand-written
mirrors of one field set (`lib/user_dto.dart`'s `UserDto`, say). Add a field to
the class and those three do not update themselves — that gap is drift, and
`keta_lints` exists to make it loud instead of a runtime surprise three requests
later. The loop, concretely:

1. Edit the class — add a field, nothing else:

   ```dart
   final String? nickname;
   ```

   (and the matching constructor parameter). `fromJson`, `toJson`, and the
   `Schema` constant are now stale: they do not read, write, or document
   `nickname`.

2. Run the checker. It fails, naming exactly what drifted:

   ```bash
   dart run keta_lints:check canonical lib/
   ```

   ```
   [<id>] keta_canonical_drift: class UserDto has drifted (fields not in
   toJson: nickname; fields not read by fromJson: nickname); run keta_lints:fix
   to reconcile the mapper (lib/user_dto.dart)
   [<id>] keta_schema_drift: class UserDto Schema constant has drifted (fields
   not in schema: nickname); run keta_lints:fix to reconcile the Schema
   (lib/user_dto.dart)
   ```

3. Run the fixer. It materializes the repair — regenerating `fromJson`,
   `toJson`, and the `Schema`'s `properties`/`required` from the field set,
   preserving everything else (enums, formats, doc comments) verbatim:

   ```bash
   dart run keta_lints:fix canonical lib/
   ```

4. Run the checker again — clean, because the three mirrors agree with the
   class once more:

   ```bash
   dart run keta_lints:check canonical lib/
   ```

`test/canonical_drift_demo_test.dart` runs exactly this loop against this
example's real `user_dto.dart` (via string surgery on a copy, never the file on
disk): it asserts the drift is caught, then that the fix clears it, so the
claim above is a passing test, not just this paragraph.

## Layout

- `lib/app.dart` — `buildApp`: the middleware stack (the single assembly point)
- `lib/routes.dart` — every route, registered on the app; the `/users` write group
- `lib/auth.dart` — `apiDefaults`, the demo `SecurityPolicy` and its tokens, `requireAdmin`
- `lib/env.dart` — the dependency graph (`Db`, `Log`, `Bus`, optional `RdsDb`) booted per isolate, from env
- `lib/events.dart` — the `users` bus topic and `userEventsStream` (`/users/events`'s SSE projection)
- `lib/readiness.dart` — `readinessPolicy`, the example `/ready` policy over `RdsDb.poolStats`
- `lib/user_dto.dart` — the canonical DTOs (`UserDto`, and the nested `UserList`)
- `migrations/` — `NNNN_name.sql`, applied in order and recorded in `_keta_migrations`
- `bin/main.dart` — migrate then serve; `tool/` — OpenAPI + dev-server scripts
