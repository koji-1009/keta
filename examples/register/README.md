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

Configuration is environment-only (§9): `KETA_DB_PATH` (default `app.db`) and
`PORT` (default `8080`).

The middleware stack (`lib/app.dart`, `buildApp`) shows the common cross-cutting concerns, in registration order: `accessLog`, `cors`, `recover`, `timeout`, request metrics (`otel`), `enforceSecurity`, and a `tx` per request. The order is load-bearing, not decoration — see the comment on `buildApp` for why (everything that can throw sits below `recover`; everything that decorates a response sits above it).

## Endpoints

| Method | Path                       | Description                          |
|--------|----------------------------|--------------------------------------|
| GET    | `/health`                  | Liveness check                       |
| GET    | `/users`                   | List users (`?limit`, `?role`); nested `UserList` |
| POST   | `/users`                   | Create a user (validated; 201 + Location) |
| GET    | `/users/:id`               | Fetch a user                         |
| PUT    | `/users/:id`               | Replace a user (404 if absent)       |
| DELETE | `/users/:id`               | Delete a user (204; 404 if absent)   |
| GET    | `/users/:uid/tags/:index`  | Read one tag by index                |
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
- `lib/routes.dart` — every route, registered on the app
- `lib/auth.dart` — `apiDefaults`, the demo `SecurityPolicy` and its tokens, `requireAdmin`
- `lib/env.dart` — the dependency graph (`Db`, `Log`) booted per isolate, from env
- `lib/user_dto.dart` — the canonical DTOs (`UserDto`, and the nested `UserList`)
- `migrations/` — `NNNN_name.sql`, applied in order and recorded in `_keta_migrations`
- `bin/main.dart` — migrate then serve; `tool/` — OpenAPI + dev-server scripts
