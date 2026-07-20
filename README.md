# keta (桁)

keta is a reflection-free, codegen-free HTTP server framework for Dart (SDK `^3.12`): routing, middleware, transactions, lifecycle, and OpenAPI output are carried by a constructor graph and routes-as-values, and the user code that results reads as plain Dart. The name keta (桁) is the load-bearing girder in traditional Japanese joinery — a member that carries load through its shape, without nails — and is also the Japanese word for "digit".

## The thesis

Structure bears the load, not machinery. There is no reflection, no DI container, no `build_runner`, and no codegen anywhere: the canonical DTO form (`fromJson`/`toJson`/`Schema`) is hand-written — or materialized once by a lint fix, transferring ownership — and kept honest by keta_lints' check/fix loop, which makes drift between a class and its mappers a loud failure rather than a runtime surprise. Derived artifacts flow one way: the declarations (`RouteDoc`/`Schema`, owned by core) are the source that both the runtime security gate and the OpenAPI emitter read, and the OpenAPI document keta_openapi produces is the one-way derived shadow — never a source that drives them. The whole surface is small enough that both humans and AI agents can write conforming code from a single short [guide](llms.txt).

## A route, three ways

```dart
import 'package:keta/keta.dart';

final app = App<void>();

void routes() {
  // String syntax: a plain handler; path parameters via c.param.
  app.get('/health', (c) => c.text('ok'));

  // Typed DSL: the path carries the capture's type, the handler gets the tuple.
  app.on(root.segments('users').capture(integer('id')))
     .get((c, (int,) p) => c.json({'id': p.$1}));

  // A documented route feeds the OpenAPI shadow; `success` is declared, not guessed.
  app.get('/version', (c) => c.json({'version': '0.1.0'}),
      doc: const RouteDoc(success: Success(), summary: 'Build version'));
}

Future<void> main() async {
  routes();
  await app.serve(() async {}, port: 8080); // env-less boot: E = void
}
```

The two routing syntaxes converge on one internal `Path` value; a documented route also emits OpenAPI 3.1 via `OpenApi.fromRoutes(app.routes, ...)`.

## Streaming and upgrades

SSE is a first-class streaming response: `c.sse(events)` renders a `Stream<SseEvent>` onto `text/event-stream` with opt-in keep-alive, opt-in `maxIdle`/`maxLifetime` bounds, and abort-driven cleanup, composing with `gzip()`/`etag()` unchanged. A WebSocket handshake is an ordinary `GET` whose handler returns `Response.upgrade(...)` — upgrade as a value, so security middleware can refuse with a plain 401 before any switch happens, the OpenAPI shadow documents the 101, and `TestClient.connect()` exercises it without a socket; an upgrade carries the same opt-in `maxIdle`/`maxLifetime` self-defense.

A streaming response lives on the isolate that produced it. To reach subscribers on the *other* worker isolates of `serve(isolates: n)`, publish through `keta_bus`: `IsolateBus` fans a message out across the process so an event raised while handling a request on one isolate reaches an SSE/WS client parked on another.

## Packages

Two axes, deliberately separate. **Ring** is measured: a package's ring is its production-dependency depth inside the workspace (dev_dependencies do not count — keta_oidc dev-depends on its own ring-2 verifier to keep its middleware tests real) — `keta` is 0, a package whose only workspace dependency is `keta` is 1, an adapter over a ring-1 abstraction is 2 — so the column is derivable from the pubspecs and verifiable by grep, never by decree. Two packages depend on nothing in the workspace at all, not even `keta`: they carry no ring (—, *standalone*) because they are not layers of the onion but independent parts the rings pull in, exactly like a third-party package. **Tier** is judged: Core/Recommended/Optional says how much of keta's story a package carries, and it does not correlate with ring — `keta_sqlite` is ring 2 yet Core, `keta_bus` is standalone yet Optional. Dependencies flow inward only (a package may depend only on strictly lower rings, plus standalone packages), and peeling off any package nothing else depends on never breaks the rest. `keta` itself has no production dependency beyond the SDK: `test` resolves only to back the shipped `test.dart` harness and is tree-shaken out of `dart compile exe` binaries.

| Package | Ring | Tier | What it is |
|---|---|---|---|
| `keta` | 0 | Core | Router, Context, middleware, server, Log, the `TestClient` harness, and the declaration contract — `Schema` validation, `RouteDoc`, and the `enforceSecurity` gate. Zero production dependencies (`test` resolves only for the shipped harness). |
| `keta_db` | 1 | Core | The `Db` abstraction (`reader`/`writer`), the `tx()` vessel, the `Env` contract, and the migration runner. |
| `keta_openapi` | 1 | Recommended | The route-table walk that emits an OpenAPI 3.1 document from `RouteDoc`/`Schema` (owned by `keta`). Pure derivation — runtime assembly, no code generation — so removing it changes no runtime behavior. |
| `keta_lints` | 1 | Recommended | Stable-ID diagnostics plus the materializing `check`/`fix` loop; the drift it catches spans canonical DTO forms, schema/contract, and field types. |
| `keta_files` | 1 | Optional | File-based routing: a file's location under `lib/routes/` is its URL, and its directory is its middleware scope. |
| `keta_shelf` | 1 | Optional | Bidirectional `Handler` ↔ `shelf.Handler` conversion, bodies streaming through with the body limit enforced. |
| `keta_multipart` | 1 | Optional | `multipart/form-data` reception as a `Stream<Part>`, bounded by `MultipartLimits`. Boundary parsing via `package:mime`. |
| `keta_otel` | 1 | Optional | `traceparent` → OTLP and a `/metrics` endpoint, with every label axis bounded (no attacker-controlled cardinality). |
| `keta_oidc` | 1 | Optional | An OIDC/OAuth2 **resource server**: it verifies the Bearer JWTs an identity provider issues and never mints or brokers tokens itself. Asymmetric-only JWT validation (RS256/RS384/RS512/ES256/ES384 — `HS*`, `alg: none`, and `PS*` are rejected by design) over a `SignatureVerifier` seam (build-free — it ships no crypto implementation of its own), a `JwksSource` seam (`StaticJwks` for fixed keys, `HttpJwksSource` for a live JWKS endpoint with OIDC Discovery and refresh discipline), and an `oidc()` / `requireScopes()` middleware pair that injects a principal and answers RFC 6750 challenges. |
| `keta_sqlite` | 2 | Core | A thin adapter over the `package:sqlite3` family; `:memory:` supported. |
| `keta_rds` | 2 | Optional | The PostgreSQL adapter — bounded pool, SQLSTATE → keta-exception translation, delegating the wire protocol to `package:postgres`. |
| `keta_oidc_boringssl` | 2 | Optional | The default `SignatureVerifier` for `keta_oidc`, over `keta_native`'s BoringSSL build. Depending on it — rather than on `keta_oidc` alone — is what triggers that from-source build. |
| `keta_bus` | — | Optional | A publish/subscribe seam, standalone and core-unaware (SDK-only, zero dependencies): `publish(topic)` / `subscribe(topic)` fan a JSON message out to live listeners, at-most-once. `InMemoryBus` (one isolate) and `IsolateBus` (fan-out across the worker isolates of `serve(isolates: n)`). |
| `keta_native` | — | Optional | The BoringSSL-backed native crypto layer, standalone and core-unaware, built via `dart hooks` (native assets): SHA-2 digests, HMAC, and RSA/ECDSA signature verification. BoringSSL is fetched pinned to a commit hash and built from source at hook time — never a prebuilt binary. |

## Deliberately out of scope for v0.1

These absences were judged, not overlooked — do not read them as gaps to fill: static file **serving** (reception via keta_multipart is separate), HTTP/2 and HTTP/3 transports (only the transport seam exists), session stores, template engines, content negotiation (keta is JSON-first), and runtime configuration reload (configuration changes by redeploy). The request-cookie primitive and typed `Set-Cookie` are in Core; session **stores** on top of them are not.

## Status

v0.1.0, under active development. Not yet on pub.dev (`publish_to: none`), and the APIs may still change. There are roughly 1,400 tests across the workspace; the `examples/` directory is the living demonstration, exercised by those tests rather than described in prose. Licensed under [MIT](LICENSE).

## Quick start

```bash
git clone https://github.com/koji-1009/keta.git
cd keta
dart pub get                    # one resolve for the whole pub workspace

cd examples/register            # a real CRUD app over SQLite, in both syntaxes
dart run bin/main.dart          # migrate, then serve on :8080
dart test                       # this example's tests

# tests run per package/example, as CI does:
for d in packages/*/ examples/*/; do [ -d "$d/test" ] && (cd "$d" && dart test); done
```

Start with [`examples/register`](examples/register) for the framework end to end — a CRUD app over SQLite in both syntaxes, whose `/users/events` route is an SSE feed fed over a `Bus` (single-isolate in-process, or fanned out across isolates via `IsolateBus`), and whose `/ready` route is a readiness probe reading pool stats. Beside it, [`examples/auth`](examples/auth) shows the bearer and session-cookie flows and a session-revocation notice that closes a live SSE stream from the server side, [`examples/oidc`](examples/oidc) a `keta_oidc` resource server verifying real Bearer JWTs (production `HttpJwksSource.discover` + `BoringSslVerifier` beside a `StaticJwks` test wiring) behind `oidc()`/`requireScopes()`, [`examples/websocket`](examples/websocket) an upgrade-as-a-value echo behind a bearer gate, and [`examples/files`](examples/files) file-based routing. Or read [llms.txt](llms.txt) — the most compressed complete description of keta, and enough to write handlers, DTOs, and tests by hand.
