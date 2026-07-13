# keta_example

A runnable keta app: a small user API over SQLite, in both routing syntaxes,
with OpenAPI output. It doubles as the reference the file-convention example
(`../example_files`) is checked against. For authentication, see
`../example_auth`.

## Run

```bash
dart run bin/main.dart
```

`main` applies any pending migrations from `migrations/` once, then serves on
`:8080` (migrations are wired into startup, not run by hand). Stop with SIGTERM
for a graceful shutdown. For a watch-and-restart dev loop: `dart run tool/dev.dart`.

## Endpoints

| Method | Path                       | Description                    |
|--------|----------------------------|--------------------------------|
| GET    | `/health`                  | Liveness check                 |
| POST   | `/users`                   | Create a user (validated body) |
| GET    | `/users/:id`               | Fetch a user                   |
| GET    | `/users/:uid/tags/:index`  | Read one tag by index          |

```bash
curl -sX POST localhost:8080/users -H 'content-type: application/json' \
  -d '{"id":"1","name":"Ada","role":"admin","tags":["x","y"]}'
curl -s localhost:8080/users/1
```

## OpenAPI

```bash
dart run tool/openapi.dart > openapi.yaml
```

The document is a shadow of the code (routes-as-values → OpenAPI 3.1); it is
never a source that drives the code.

## Layout

- `lib/routes.dart` — every route, registered on the app
- `lib/env.dart` — the dependency graph (`Db`, `Log`) booted per isolate
- `lib/user_dto.dart` — the canonical DTO + its `Schema` constant
- `migrations/` — `NNNN_name.sql`, applied in order and recorded in `_keta_migrations`
- `bin/main.dart` — migrate then serve; `tool/` — OpenAPI + dev-server scripts
