# keta_auth_example

A reference for **declaration-driven authentication** in keta. keta ships no
auth (spec §10) — you declare what a route requires and wire one gate; keta owns
only the plumbing that matches declarations to your verifiers.

One line per route drives three things from a single source:

- **OpenAPI** — `RouteDoc(security: [bearer])` emits `security: [{bearer: []}]`,
  an automatic `401`, and a `bearer` entry under `components/securitySchemes`.
- **Runtime** — a single upstream `app.use(enforceSecurity(policy))` reads the
  matched route's declaration from `c.routeDoc` and raises `Unauthorized` (401)
  when no verifier passes. "declared but unenforced" is structurally impossible.
- **Authorization** stays ordinary app middleware: a `requireRole('admin')`
  guard raises `Forbidden` (403). keta never owns the credential check itself.

`lib/auth.dart` is the app's part: a `SecurityPolicy` whose `bearer` verifier
resolves a token to a role (swap the stand-in table for a JWT or session
unchanged) and the role guard.

`SecurityPolicy(defaults: [bearer])`: a route that declares no security fails closed (401), matching `../example` and `../example_files`. `/public` is public only because it says so explicitly (`RouteDoc(security: const [])`) — forgetting that declaration would 401 it, not leave it open.

## Run

```bash
dart run bin/main.dart              # serves on :8080 (no database)
dart run tool/openapi.dart          # prints the OpenAPI, security included
```

## Try it

```bash
curl -s localhost:8080/public                                                # 200, public
curl -s localhost:8080/admin/whoami                                          # 401, no token
curl -s localhost:8080/admin/whoami -H 'authorization: Bearer member-token'  # 403, wrong role
curl -s localhost:8080/admin/whoami -H 'authorization: Bearer admin-token'   # 200 {"role":"admin"}
```

Tokens: `admin-token` → `admin`, `member-token` → `member`.
