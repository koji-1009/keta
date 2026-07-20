# keta_files_example

The same app as [`../register`](../register), registered by **file convention**
(keta_files) instead of one central `register()`. Each file under `lib/routes/`
declares a single `exported` (`Exported<Env>`); `dart run keta_files:sync` materializes their imports
and `bind` calls into the marked regions of `lib/routes.dart`. Everything else — the
domain, the middleware stack, the routes, the security declarations — matches
the register-based example.

This tree covers the CRUD surface, not all of it: `../register` has since grown
`/users/by-role/:role` (a custom `Capture`) and `/users/events` (an SSE feed),
and neither is mirrored here — that would need an events bus and a custom SSE
capture in keta_files, a piece of work of its own, not a copy-paste. What is
true, and enforced by `test/files_test.dart`'s `'the shared CRUD surface
documents identically to ../register'`, is that the routes both examples serve
emit **byte-identical OpenAPI** — the test builds both documents, restricts
`../register`'s to exactly this tree's path set, and asserts deep equality on
that subset, so the claim cannot silently rot the next time either side
changes.

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

Drop a file under `lib/routes/` with a top-level `exported` (`Exported<Env>`), then:

```bash
dart run keta_files:sync            # wire it into lib/routes.dart
dart run keta_files:check           # CI gate: fails if any file is unregistered
```

`lib/routes/uploads.dart` (a multipart upload via keta_multipart) shows exactly
this — a route added as its own file and synced in.

## Writes open their own transaction — keta_files has no per-verb middleware

`../register` scopes `tx()` (keta_db) to a `/users` write group via
`app.group('/users').use(tx())`, so reads never pay for a transaction they
don't need. keta_files has no equivalent: `ScopedMiddleware` is
directory-scoped, and `Exported.bind` wraps every verb a route file serves
(`get`/`post`/`put`/`delete`) in the identical chain — there is no way to
mount middleware over only `routes/users.dart`'s `post` slot while leaving
its `get` slot bare. So the write handlers in `routes/users.dart` and
`routes/users/_id.dart` open their own transaction directly instead —
`c.env.db.transaction((conn) => conn.execute(...))`, no `tx()` middleware and
no `txConn` Key — which scopes it even tighter than a route group would (to
exactly the write handler's own body). See `lib/routes.dart`'s `buildApp` doc
for the full reasoning.

## The list envelope is `listSchema`, not hand-written

`lib/user_dto.dart`'s `userListSchema` is `listSchema(userDtoSchema)`
(from `keta`) rather than a hand-written `const Schema` — mirrors
`../register`'s identical change, which is what keeps this section's
"documents identically" claim (and its test) true. One behavior change comes
with it: `listSchema` closes the envelope (`additionalProperties: false`),
which the hand-written version left open. `listSchema` builds a new `Schema`
per call rather than reading a `const`, so `routes/users.dart`'s `RouteDoc`
that embeds it is no longer `const` either.

## Layout

- `lib/routes/` — one file per concern, each with its own `exported`
- `lib/routes.dart` — the manifest: the middleware stack plus the generated
  import/register regions (edit those only through `sync`)
- `lib/env.dart`, `lib/user_dto.dart` — the domain (copied from `../register`)
