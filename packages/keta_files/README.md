# keta_files

File-based routing for keta. A file's location under `lib/routes/` **is** its URL, and its directory **is** its middleware scope. The tree is the routing table; reading the tree is reading the routes. Nothing is derived by parsing route files — what each file contributes is a typed value the compiler checks, so a wrong shape is a compile error rather than a route that silently never serves.

## The file-based routing contract

### A location is a URL

```
lib/routes/index.dart                  → /
lib/routes/health.dart                 → /health
lib/routes/users.dart                  → /users
lib/routes/users/_id.dart              → /users/:id
lib/routes/users/_uid/tags/_index.dart → /users/:uid/tags/:index
lib/routes/admin/ping.dart             → /admin/ping
```

- A leading `_` on a file or directory is a **capture**: `_id` is `:id`. (`_id` rather than `[id]` because the `file_names` lint rejects `[id].dart`.)
- `index.dart` denotes its directory, not a segment called `index`.
- Every file under the tree is a route — there is nowhere to hide a helper, which is what makes the tree readable as the route table. (The one exception is the middleware file below, which is not a route.)
- No route file names its own URL. Moving a file moves its URL with no edit to the file.
- Two files denoting one URL is a `FormatException`: nothing in the tree says which would win.

### A file states what it serves

One file is one URL, so it is one value. A route file declares a single `exported`:

```dart
final exported = Exported<Env>(
  get: Serve(_fetch, doc: const RouteDoc(summary: 'Fetch a tag')),
  put: Serve(_replace),
  captures: {'index': integer},
);
```

- **One slot per method** — the seven keta binds, the whole closed set. A URL cannot answer a method twice because there is nowhere to write it twice.
- **`Serve` pairs a handler with its doc**, because they describe one thing; held apart and matched by name, a rename silently unbinds the doc.
- **`captures` sits beside the slots**, because a capture belongs to the URL: `/users/:id` has an `id` whether it is fetched, replaced, or deleted. A capture absent from the map is a `string`; a declared one (`{'index': integer}`) is the only way `type: integer` reaches the OpenAPI document and turns `/tags/abc` into a 400.
- A file that serves nothing **fails at boot, naming the URL**.

## Directory-scoped middleware

A directory scopes middleware over every route beneath it — the file-based answer to `app.group('/admin').use(...)`, except the **directory stands in for the prefix**. A `_middleware.dart` file declares a single typed `scoped`:

```dart
// lib/routes/admin/_middleware.dart — scopes everything under /admin
final scoped = ScopedMiddleware<Env>([requireAdmin()]);
```

- **The directory is the scope.** `routes/admin/_middleware.dart` wraps every route under `/admin`; `routes/_middleware.dart` wraps the whole tree; `routes/users/_id/_middleware.dart` wraps the capture subtree `/users/:id/...`. Nothing inside the file names the scope, the same way no route file names its URL.
- **`_middleware.dart` is never a route.** It is carved out of discovery before capture interpretation, so its leading `_` never reads as a `:middleware` capture, and it never appears in the route table or the `unregistered` check.
- **One typed value, checked at compile time.** `ScopedMiddleware<Env>` mirrors `Exported<Env>`: a misspelled or wrong-typed value is a compile error at the generated binding line, not a scope that silently never runs. The generator never parses the file — it emits `$mw$admin.scoped` and lets the type system do the checking.

### Ordering

For a route at `routes/admin/audit/log.dart` with middleware at `routes/_middleware.dart` and `routes/admin/_middleware.dart`, a request runs:

```
app.use middleware  →  routes/_middleware  →  routes/admin/_middleware  →  handler
   (app-wide)             (root scope)            (admin scope)
```

App-wide middleware (`app.use`) wraps the whole dispatch, including 404/405 synthesis. Directory scopes compose **inside** it, outer directory before inner directory before the handler — the same left-to-right discipline as keta's own `..use(...)`. Within a single `_middleware.dart`, the list order is the run order. Any scope may short-circuit (return a response without calling `next`), which is the point of scoping authorization to a subtree.

### A scope guarding nothing

A `_middleware.dart` whose directory has no route beneath it is **dead weight**: its `scoped` wraps nothing, so it is imported nowhere. `keta_files:check` names it as its own condition — a scope silently guarding nothing is exactly the quiet failure this package exists to make loud.

## The generated manifest

`dart run keta_files:sync` materializes the tree into the marked regions of `lib/routes.dart`. What runs is ordinary keta code you can read:

```dart
void register(App<Env> app) {
  // keta_files:imports
  // dart format off
  import 'routes/admin/ping.dart' as $admin_ping;
  import 'routes/_middleware.dart' as $mw$root;
  import 'routes/admin/_middleware.dart' as $mw$admin;
  // dart format on
  // keta_files:end
  // keta_files:routes
  // dart format off
  $admin_ping.exported.bind(app, const ['admin', 'ping'], [$mw$root.scoped, $mw$admin.scoped]);
  // dart format on
  // keta_files:end
}
```

- **Aliases live in `$`.** A route alias is one `$` then the URL's own words (`$admin_ping`); a middleware alias carries a second `$` (`$mw$admin`). Neither can collide with app code, and the two namespaces cannot intersect — a route file named `mw` and a root scope are aliased apart by construction.
- **A route under no scope keeps the plain two-argument form** (`$health.exported.bind(app, const ['health']);`), so an ordinary manifest neither churns nor grows.
- **Regions are fenced with `// dart format off`/`on`.** A binding wider than 80 columns would otherwise be reflowed by the formatter, the next sync would write it back, and "syncing is a no-op" — the one assertion between the tree and the routes — could not hold.
- **Sync is idempotent** and a pure function of the tree: the same tree writes the same manifest, imports and bindings alike.

## The CI gate

`dart run keta_files:check` exits non-zero when the manifest and the tree disagree, so drift fails CI:

- **not served** — a route file the manifest does not bind. Its URL would 404 despite the file compiling and the tests passing. `run keta_files:sync` to bind it.
- **scopes no route** — a `_middleware.dart` guarding nothing beneath it.

## Commands

```bash
dart run keta_files:sync [routesDir] [manifest]   # materialize the tree into the manifest
dart run keta_files:check [routesDir] [manifest]  # CI gate: fail on drift
```

Defaults: `routesDir` `lib/routes`, `manifest` `lib/routes.dart`. The manifest must already contain the `// keta_files:imports` / `// keta_files:routes` markers, each closed by `// keta_files:end`.
