# keta_oidc_example

A reference **resource server** built on `keta_oidc`: it verifies Bearer JWTs
an identity provider issues, injects the resulting principal, and authorizes
on scope. Unlike `../auth` (app-defined bearer tokens and cookie sessions,
with a session-revocation demonstration), this example shows the OIDC/OAuth2
side — real JWT validation over BoringSSL, real JWKS sourcing, and the RFC
6750 challenge shapes `keta_oidc`'s `oidc()` middleware answers with. The two
examples are deliberately separate: they demonstrate different credential
models, not two ways to do the same thing.

## What it demonstrates, route by route

- **`GET /public`** — no token needed (`RouteDoc(security: [])`, the same
  explicit-opt-out `../auth`'s `/public` uses). Reachable before `oidc()` ever
  runs — it isn't under the `/api` group at all.
- **`GET /api/me`** — behind `oidc()`. Returns the authenticated principal:
  `sub`, the granted `scopes` (parsed from the token's `scope`/`scp` claim —
  see `OidcPrincipal`), and an `org` field read straight from
  `principal.claims.raw['org']` — a stand-in for whatever custom claim your
  IdP actually mints (a tenant id, a department, ...). `claims.raw` is where
  every non-registered claim lives; `keta_oidc` only lifts the RFC 7519
  registered ones (`iss`/`sub`/`aud`/`exp`/`nbf`/`iat`) to typed fields.
- **`GET /api/reports`** — behind `oidc()` **and**
  `requireScopes(['reports:read'])`. A token missing that scope gets a `403`
  with a `WWW-Authenticate: Bearer error="insufficient_scope"` challenge
  naming it; a token holding it gets the (tiny, hardcoded) report list `Env`
  carries. This is the scope-authorization half `oidc()` alone doesn't do —
  `oidc()` only authenticates; `requireScopes()` is the separate, composable
  authorization step that runs after it.
- **`GET /api/me/events`** — an SSE feed, behind the *same* `oidc()` as `/me`.
  It exists to make one point concrete: because `oidc()` answers **before**
  the handler is ever called, an unauthenticated request to a streaming route
  never opens a stream at all — it gets an ordinary `401` JSON body, the exact
  same shape `/api/me` would return. Authenticated, it opens a
  `text/event-stream` tick feed carrying the caller's own `sub`.

## Two JWKS sources, one validator, one `oidc()`

`bin/main.dart` (production) and `test/oidc_example_test.dart` (tests) both
build a `JwksSource` and a `JwtValidator` and hand the *same two objects* to
both `buildApp()` (which wires `oidc()` with them) and `Env` (which carries
them for anything else that might need them) — see `lib/env.dart`'s doc for
why that is the one wiring `keta_oidc` supports. Only the JWKS source differs
between the two:

- **Production** (`bin/main.dart`): `HttpJwksSource.discover(issuer: ...)` —
  finds `jwks_uri` via OIDC Discovery, then fetches, caches, and refreshes
  real keys over HTTP from whatever OIDC provider you point it at.
- **Tests** (`test/oidc_example_test.dart`): `StaticJwks` over a JWKS document
  built from a key pair `package:keta_native/testing.dart` generates in-process
  — no network, no live IdP, but the **same** `BoringSslVerifier` doing the
  **same** real signature check. A test token is signed with
  `RsaKeyPair.signPkcs1Sha256` over the real `"<header>.<payload>"` signing
  input, so what's being proven is the actual crypto path, not a stub of it.

Every route is driven through `TestClient` — no sockets — mirroring `../auth`'s
test style: anonymous → `401` (bare challenge), a malformed
token → `401` (`invalid_token`), a token missing a required scope → `403`
(`insufficient_scope`), a good token → `200` with the expected body. The SSE
route's authenticated path is checked by dispatching a raw `TransportRequest`
and reading only the response's status and `content-type` — draining an SSE
body via `TestClient` would hang forever, the same reason
`../auth/test/revocation_test.dart` builds its own minimal request type.

## What this example inherits as judged absences

Everything `keta_oidc`'s own README documents as a judged absence applies
here unchanged — this example adds no policy on top of the package:

- **No login flow.** This is the resource-server side of OIDC only; minting a
  token (Authorization Code + PKCE, refresh tokens, a login page) is a
  different program with a different threat model. Get a token from your IdP
  by whatever flow it supports, then send it as `Authorization: Bearer <token>`.
- **No remote token introspection.** Validation is local, against cached JWKS.
- **Revocation is short token TTL, not a live check per request.** If you need
  a server-initiated "kill this session now" the way `../auth` demonstrates,
  that pattern (a revocation notice on `keta_bus`, closing an open SSE stream
  from the server's side) composes on *top* of `keta_oidc` — pair a short
  access-token lifetime with your own push-revocation channel for anything
  that must react faster than the token's `exp`.
- **`HS*`, `alg: none`, and `PS*` tokens are rejected before a key is even
  consulted** — asymmetric-only by design (RS256/RS384/RS512/ES256/ES384).

## Run it standalone (no identity provider)

`bin/demo.dart` runs the exact same server with **no IdP and no network** — it
plays the identity provider itself, so you can try every route in one command.
It generates a key with `package:keta_native/testing.dart`, publishes it as a
`StaticJwks`, mints one valid token, and serves; a real deployment never signs
anything (that is the IdP's job — this server only verifies), so this is a
demo-only shortcut, but the verification it exercises is the real
`BoringSslVerifier` path, not a stub.

```bash
dart run bin/demo.dart               # serves on :8080, prints a DEMO_TOKEN=… line
```

The token it prints (valid an hour, scope `reports:read`) drives the protected
routes directly:

```bash
curl -s localhost:8080/api/me      -H "authorization: Bearer $DEMO_TOKEN"   # 200
curl -s localhost:8080/api/reports -H "authorization: Bearer $DEMO_TOKEN"   # 200
```

To build the shipping AOT binary, use `dart build cli` — **not**
`dart compile exe`, which cannot build this: `keta_native` and `package:sqlite3`
carry build hooks, and only `dart build` runs them. The bundle is a self-
contained executable beside its native libraries:

```bash
dart build cli -t bin/demo.dart -o build   # build/bundle/bin/demo + build/bundle/lib/
PORT=8080 ./build/bundle/bin/demo
```

## Run it against a real identity provider

Any OIDC provider works — Auth0, Okta, Keycloak, Azure AD, Google, your own.
You need its issuer URL and the audience (API identifier) it mints tokens
for:

```bash
KETA_OIDC_ISSUER=https://your-tenant.example.com/ \
KETA_OIDC_AUDIENCE=api://your-api \
dart run bin/main.dart              # serves on :8080
```

Unset either variable and `main()` fails immediately, before binding a port,
naming exactly what's missing — not a 500 on the first request that needed it.
`bin/main.dart` also hardcodes the algorithm allowlist to `{RS256}`; widen it
in `bin/main.dart` only to the algorithms your IdP actually
signs with (see `JwtValidator`'s doc on why the tightest correct set is
per-deployment).

```bash
curl -s localhost:8080/public                                          # 200, public
curl -s localhost:8080/api/me                                          # 401, no token
curl -s localhost:8080/api/me -H "authorization: Bearer $TOKEN"        # 200, principal
curl -s localhost:8080/api/reports -H "authorization: Bearer $TOKEN"   # 403 or 200, by scope
curl -N localhost:8080/api/me/events -H "authorization: Bearer $TOKEN" # SSE ticks
```

```bash
dart run tool/openapi.dart          # prints the OpenAPI, security included
dart test                           # this example's tests (no network, no IdP)
```
