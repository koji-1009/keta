# keta_auth_example

A reference implementation of **app-defined authentication** for keta. keta
ships no auth (spec §10) — this is the pattern to copy, not a framework feature.
It is deliberately built from primitives keta already gives you:

- `Middleware<E>` — compose `auth()` then a `requireRole(...)` guard on a group
- `Key<T>` + `Context.set/get` — carry the authenticated role downstream
- `c.header('authorization')` — read the credential
- `Unauthorized` (401) / `Forbidden` (403) — short-circuit with the right status
- `app.group(prefix)..use(...)` — apply the guards to a subtree, on match only

`lib/auth.dart` is ~30 lines. A real app swaps the stand-in token table for a
JWT or session check — the middleware shape is unchanged.

## Run

```bash
dart run bin/main.dart   # serves on :8080 (no database)
```

## Try it

```bash
curl -s localhost:8080/public                                              # 200, open
curl -s localhost:8080/admin/whoami                                        # 401, no token
curl -s localhost:8080/admin/whoami -H 'authorization: Bearer member-token'  # 403, wrong role
curl -s localhost:8080/admin/whoami -H 'authorization: Bearer admin-token'   # 200 {"role":"admin"}
```

Tokens: `admin-token` → `admin`, `member-token` → `member`.
