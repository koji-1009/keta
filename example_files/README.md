# keta_files_example

The same app as [`../example`](../example), registered by **file convention**
(keta_files) instead of one central `register()`. Each file under `lib/routes/`
exposes `register(app)`; `dart run keta_files:sync` materializes their imports
and calls into the marked regions of `lib/routes.dart`. Everything else — the
domain, the middleware stack, the routes — matches the register-based example,
so the two emit **byte-identical OpenAPI**. Only the registration mechanism
differs.

## Run

```bash
dart run bin/main.dart              # KETA_DB_PATH / PORT from the environment
dart run tool/openapi.dart          # the OpenAPI shadow (identical to ../example)
```

## Adding a route

Drop a file under `lib/routes/` with a top-level `register(App<Env> app)`, then:

```bash
dart run keta_files:sync            # wire it into lib/routes.dart
dart run keta_files:check           # CI gate: fails if any file is unregistered
```

`lib/routes/uploads.dart` (a multipart upload via keta_multipart) shows exactly
this — a route added as its own file and synced in.

## Layout

- `lib/routes/` — one file per concern, each with its own `register`
- `lib/routes.dart` — the manifest: the middleware stack plus the generated
  import/register regions (edit those only through `sync`)
- `lib/env.dart`, `lib/user_dto.dart` — the domain (copied from `../example`)
