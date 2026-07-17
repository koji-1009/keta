# keta_example

A runnable keta app: a small user API over SQLite, in both routing syntaxes,
with OpenAPI output. It doubles as the reference the file-convention example
(`../example_files`) is checked against. For authentication, see
`../example_auth`.

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

## Layout

- `lib/app.dart` — `buildApp`: the middleware stack (the single assembly point)
- `lib/routes.dart` — every route, registered on the app
- `lib/auth.dart` — `apiDefaults`, the demo `SecurityPolicy` and its tokens, `requireAdmin`
- `lib/env.dart` — the dependency graph (`Db`, `Log`) booted per isolate, from env
- `lib/user_dto.dart` — the canonical DTOs (`UserDto`, and the nested `UserList`)
- `migrations/` — `NNNN_name.sql`, applied in order and recorded in `_keta_migrations`
- `bin/main.dart` — migrate then serve; `tool/` — OpenAPI + dev-server scripts
