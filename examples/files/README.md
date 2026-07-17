# keta_files_example

The same app as [`../register`](../register), registered by **file convention**
(keta_files) instead of one central `register()`. Each file under `lib/routes/`
exposes `register(app)`; `dart run keta_files:sync` materializes their imports
and calls into the marked regions of `lib/routes.dart`. Everything else — the
domain, the middleware stack, the routes, the security declarations — matches
the register-based example, so the two emit **byte-identical OpenAPI**.

How `/admin/ping`'s authorization is wired now matches too. `../register`
scopes a `requireAdmin()` middleware over the whole `/admin` subtree with
`app.group('/admin').use(requireAdmin())`; keta_files' answer is
`routes/admin/_middleware.dart`, a file declaring a single typed
`ScopedMiddleware<Env>([requireAdmin()])` whose *directory* stands in for the
prefix. `dart run keta_files:sync` gathers every `_middleware.dart` on the
path from `lib/routes/` down to a route file and threads them into that
route's `Exported.bind` call, outer scope first — `routes/admin/ping.dart`
itself is back to a plain handler with no inline authorization check. See
`packages/keta_files/README.md`'s "Directory-scoped middleware" section for
the full contract.

## Run

```bash
dart run bin/main.dart              # KETA_DB_PATH / PORT from the environment
dart run tool/openapi.dart          # the OpenAPI shadow (identical to ../register)
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
- `lib/env.dart`, `lib/user_dto.dart` — the domain (copied from `../register`)
