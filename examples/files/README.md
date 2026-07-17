# keta_files_example

The same app as [`../register`](../register), registered by **file convention**
(keta_files) instead of one central `register()`. Each file under `lib/routes/`
exposes `register(app)`; `dart run keta_files:sync` materializes their imports
and calls into the marked regions of `lib/routes.dart`. Everything else — the
domain, the middleware stack, the routes, the security declarations — matches
the register-based example, so the two emit **byte-identical OpenAPI**.

One thing does *not* match: how `/admin/ping`'s authorization is wired.
`../register` scopes a `requireAdmin()` middleware over the whole `/admin`
subtree with `app.group('/admin').use(requireAdmin())`. keta_files has no
equivalent — `Exported.bind` always registers a file's handlers straight onto
the one flat `App<E>` that `register(app)` receives (there is no per-file or
per-subtree group to hang middleware on), and the manifest that calls `bind`
is generated, not hand-editable. So `routes/admin/ping.dart` inlines the same
check (`c.tryGet(principal)` / `Forbidden`) in its handler instead of via
middleware — the same authorization outcome, reached without a group-scoping
mechanism that the file-convention has no surface for.

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
