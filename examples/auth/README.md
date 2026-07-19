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

`SecurityPolicy(defaults: [bearer])`: a route that declares no security fails closed (401), matching `../register` and `../files`. `/public` is public only because it says so explicitly (`RouteDoc(security: const [])`) — forgetting that declaration would 401 it, not leave it open.

## Two verifiers, one gate

The bearer table above and the cookie session below are the same gate
(`enforceSecurity`, one upstream `app.use`) with two different verifiers —
that is the whole demonstration. A route just names the scheme it accepts
(`security: [bearer]` or `security: [cookieAuth]`); the runtime 401, the
OpenAPI `security` entry, and the `components/securitySchemes` document all
follow from that one declaration, regardless of which verifier services it.

`/login` verifies a username/password against a demo credential table (the
same kind of stand-in `_tokens` is for bearer), mints a random session id
(`Random.secure`, hex — the same idiom `App` uses for request ids), stores
`sid -> role` in an in-memory `Map` owned by `Env`, and renders it as a
`Set-Cookie` (`httpOnly`, `SameSite=Lax`) onto the response headers — there is
no second channel for a cookie, just the ordinary multi-value headers keta
already has. `/me` and `/logout` read `c.cookie('sid')` back and look it up in
that same store. keta ships no session store by design (the same "keta ships
no auth" rule bearer already demonstrates); the in-memory `Map` on `Env` is
the app's own state, and a real app swaps it for Redis or a database table
without touching the verifier, `/me`, or `/logout`.

Cookie auth is documented in OpenAPI as an `apiKey`-style scheme
(`type: apiKey, in: cookie, name: sid`) — keta_openapi ships `bearer` and a
header-carried `apiKey`, so this example mints its own `cookieAuth`
`SecurityScheme` constant for the cookie-carried case.

`secure: true` is deliberately **not** set on the login cookie — this demo
serves plain HTTP, and a browser drops a `Secure` cookie sent over an
insecure connection outright. A production deployment over TLS must add
`secure: true`; `SameSite.none` would require it by construction (`SetCookie`
enforces that pairing at construction, so the mistake is unrepresentable).

## Password storage: this demo has none — a real app needs hashing

`lib/auth.dart`'s `_credentials` table checks a login password with a plain
`!=` string comparison against a constant, in-memory map — there is no
hashing, salting, or storage of any kind here, because there is no real
credential store to protect: `_credentials` is the same kind of demo
stand-in `_tokens` is for bearer. A real application storing passwords must
never compare or persist them as plain text; use a purpose-built,
slow-by-design hash from the **argon2 family** (Argon2id is the current
general recommendation) via one of the argon2 packages on pub.dev, hash at
signup, and compare with the algorithm's own verify function at login —
never `==`/`!=` on a hash or a plaintext password.

## Revocation closes a live connection, from the server's side

`/me/events` is a second SSE feed, alongside `../register`'s `/users/events`,
demonstrating a different pattern on the same primitives (`keta_bus`,
`c.sse`): **a token/session is revoked → a revocation notice is published on
the bus → the server closes the affected live connection itself.** `/logout`
(`lib/auth.dart`'s `logout`) both removes the session from the store (the
ordinary auth consequence — `/me` 401s afterward, same as always) and
publishes `{"kind":"revoked"}` to that session's own bus topic
(`sessionTopic(sid)`, one topic per session id). `/me/events` subscribes to
exactly that topic and streams what arrives; the moment it sees `revoked`,
`sessionEvents` closes its `StreamController` in that same callback (built on
an explicit `StreamController`, not an `async*` generator — see
`lib/auth.dart`'s doc on `sessionEvents` for the cancellation-leak bug that
ruled the generator shape out) — which ends the source stream `c.sse` is
built on, and keta closes the HTTP response the instant its source ends (see
`packages/keta/lib/src/sse.dart`). The client never has to notice anything or
hang up: the server tears the connection down from its own side, in the same
tick the revocation notice is delivered.

This is a demonstrated **application pattern**, not a keta mechanism — keta
supplies `Bus`, `c.sse`, and nothing else; the "revoke → publish → the stream
watches its own topic and ends itself" shape lives entirely in
`lib/auth.dart`. `test/revocation_test.dart` proves the connection actually
terminates (not merely that a `revoked` event was sent), and that a session
which is never revoked keeps its feed open indefinitely — the close is
conditional on revocation, not a timeout or a fixed lifetime.

This example runs single-isolate, so its bus is a plain `InMemoryBus`
(`lib/env.dart`, Env-owned, closed on shutdown like keta_otel's exporter); see
`../register`'s `Env` and `bin/main.dart` for the `IsolateBus` wiring a
multi-isolate app needs for the same pattern to reach a revocation published
on one isolate to a connection held open on another.

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

# Cookie session: /login sets the cookie, /me and /logout spend it.
curl -sc /tmp/cookies -X POST localhost:8080/login \
  -H 'content-type: application/json' -d '{"username":"admin","password":"admin-pass"}'
curl -sb /tmp/cookies localhost:8080/me                                      # 200 {"role":"admin"}
curl -sX POST -b /tmp/cookies localhost:8080/logout                          # 200, session ended
curl -sb /tmp/cookies localhost:8080/me                                      # 401, sid no longer valid
```

Bearer tokens: `admin-token` → `admin`, `member-token` → `member`. Login
credentials: `admin`/`admin-pass`, `member`/`member-pass` (same two roles, a
different credential shape).
