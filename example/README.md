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

The middleware stack shows the common cross-cutting concerns: `accessLog`,
`cors`, request metrics (`otel`), `recover`, and a `tx` per request.

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

```bash
curl -sX POST localhost:8080/users -H 'content-type: application/json' \
  -d '{"id":"1","name":"Ada","role":"admin","tags":["x","y"]}'
curl -s 'localhost:8080/users?role=admin&limit=10'
curl -sX PUT localhost:8080/users/1 -H 'content-type: application/json' \
  -d '{"id":"1","name":"Ada B","role":"member","tags":[]}'
curl -sX DELETE localhost:8080/users/1 -o /dev/null -w '%{http_code}\n'
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
- `lib/env.dart` — the dependency graph (`Db`, `Log`) booted per isolate, from env
- `lib/user_dto.dart` — the canonical DTOs (`UserDto`, and the nested `UserList`)
- `migrations/` — `NNNN_name.sql`, applied in order and recorded in `_keta_migrations`
- `bin/main.dart` — migrate then serve; `tool/` — OpenAPI + dev-server scripts
