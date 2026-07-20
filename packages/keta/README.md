# keta

The Ring 0 core of [keta](../../README.md): router, `Context`, middleware, the `serve` lifecycle, `Log`, the HTTP/1.1 transport, the `TestClient` harness, and the declaration contract — `Schema` validation, `RouteDoc`, and the `SecurityPolicy`/`enforceSecurity` runtime gate. It depends on nothing but the Dart SDK — the only entry in `pubspec.yaml` is `test`, which resolves solely to back the shipped `package:keta/test.dart` harness and is tree-shaken out of `dart compile exe` binaries. Everything above it (database, OpenAPI emission, OIDC, ...) is an outer ring that can be peeled off without touching this package; see the root README's [package table](../../README.md#packages).

## Routing: two syntaxes, one `Path`

The string syntax and the typed DSL converge on the same internal `Path` value and the same radix-trie dispatch:

```dart
final app = App<void>();

// String syntax: parameters read via c.param.
app.get('/users/:id', (c) => c.text(c.param<String>('id')));

// Typed DSL: the path carries the capture types; the handler gets the tuple.
app.on(root.segments('users').capture(integer('id')))
   .get((c, (int,) p) => c.json({'id': p.$1}));
```

Verbs are `get post put delete patch head options`, each taking an optional `doc: RouteDoc?` — the route's OpenAPI/security contract, read by this package's own `enforceSecurity` gate and by keta_openapi's emitter. Paths build from `root` with `.segments('a/b')` (literals) and `.capture(...)` (built-in captures `string`, `integer`, `number`, `boolean`; a custom `Capture<T>` is a `parse` + `schema` pair whose `parse` throws `BadRequest` on invalid input). The typed tuple form covers one to four captures (`PathCapture0`–`PathCapture3`). `app.group('/prefix')` scopes middleware to a subtree. Registration fails fast: the same method + template twice is a `StateError` when the table compiles (at `serve` or `TestClient` construction — both run the same `compile`), and a duplicate capture name throws at registration. Match precedence is literal over capture, with backtracking; an unmatched path is a 404, a matched path with the wrong method is a 405 carrying the RFC 9110 `Allow` header.

## Context

`Context<E>` is a zero-cost extension type over the per-request state: `c.env`, `c.method`, `c.uri`, `c.header`/`c.headerAll` (lower-cased; single/multi-value symmetry), `c.cookie`/`c.cookies` (RFC 6265 pair parsing, malformed pairs skipped, first-wins on duplicates), `c.remoteAddress` (resolved lazily — most handlers never read it, and the eager syscall measured 10.6% of hot-path CPU). `c.param<T>` parses a path capture as `String`/`int`/`double`/`bool` (bad input → 400); `c.query<T>` shares the type contract but makes absence a 400 — required-ness is expressed by which accessor you call, so `c.tryQuery<T>` is the optional form (absence → null) and `c.queryAll<T>` reads repeated keys (absence → `[]`). Per-request values flow through identity-compared `Key<T>` via `c.get`/`c.tryGet`/`c.set`. `c.body()` decodes JSON once and caches it (bad JSON → 400, over `maxBodyBytes` → 413); `c.bodyBytes()`/`c.bodyStream()` are the raw forms, and a failed read stays sticky so a re-read reproduces the original 413 or I/O error instead of an opaque "already listened" 500. `c.aborted` completes on timeout or client disconnect — cancellation is cooperative. Responses come from `c.json(value, {status})` and `c.text(str, {status})`; a `SetCookie` value renders onto ordinary headers via `toHeaderValue()`, with header injection made unrepresentable at construction and `SameSite.none` requiring `secure: true`.

`c.routeTemplate` is the matched route's template (`/users/:id`) — the bounded-cardinality dimension for logs, metrics, and spans. The raw request path is attacker-controlled and unbounded, so it never substitutes for it: an unmatched request logs the exported constant `unmatchedRoute` (`'(unmatched)'`), and there is no route-shaped accessor that falls back to the raw path.

## Errors

`KetaException` is sealed: `BadRequest` (400), `Unauthorized` (401), `Forbidden` (403), `NotFound` (404), `Conflict` (409), `PayloadTooLarge` (413), `UnprocessableEntity` (422), `NotImplementedYet` (501), `Unavailable`/`TransientFailure` (both 503 — the latter names a lost concurrency race, so `is TransientFailure` is the retry check), `GatewayTimeout` (504), plus the `KetaException.status` factory for anything else. Throw one and the response carries its status with `{"error": message}`; every other exception is a defect → 500, logged, no detail leaked. `recover()` is the customizable middleware form (it also logs a `KetaException`'s operator-only `detail`), but a non-removable last-resort fallback in the router applies the same conversion regardless — safety is not conditional on registering it.

## Middleware

`app.use(...)` composes in registration order, app-wide before group, and app-level middleware wraps the whole dispatch including the 404/405 synthesis (so CORS preflight and access logging cover unmatched requests too). Built-ins: `accessLog()` (one line per request with honesty markers — `streaming: true`/`upgrade: true`, where `ms` is time-to-response, not stream lifetime), `recover()`, `cors(allowOrigins: [...])` (preflight, `Vary: Origin` union), `etag()` (strong FNV-1a 64 tag on buffered 200 bodies, RFC 9110 weak-comparison 304s; stream bodies pass through), `gzip({threshold: 1024})` (negotiated compression with `Vary: Accept-Encoding` union; register gzip before etag so the tag is computed pre-encoding), `timeout(Duration)` (504 + `c.aborted`), and `tracing()` (strict W3C `traceparent` → `c.get(traceKey)`; a malformed header is treated as absent, never an error).

## Admission control and self-defense

`rateLimit(key:, capacity:, refillPeriod:)` is a per-key token bucket: a `null` key exempts the request entirely, a refusal is a bare 429 `Response` (deliberately no 429 `KetaException` member) with an always-honest `Retry-After` in whole seconds, and full buckets are swept so memory stays proportional to the keys currently being throttled, not to a hostile key space. `concurrencyLimit(maxInFlight:)` sheds past an in-flight ceiling with a bare 503 and no `Retry-After` (a free-slot time is unknowable); a slot spans request entry to the `Response` value being produced — never a streamed body's or upgraded socket's lifetime, so idle SSE/WS clients cannot pin every slot. Both are per-isolate by design: under `serve(isolates: n)` the effective limit is the configured value × `n` — size it as `desired / isolates`.

`timeout()` bounds time-to-response only: it arms no timer for a synchronously produced response, which SSE and upgrades both are. Long-lived streams bound themselves instead, via the opt-in `maxIdle`/`maxLifetime` on `c.sse` and `Response.upgrade` — null by default, because keta never starts a timer the caller did not ask for.

## SSE and WebSocket upgrade as a value

`c.sse(Stream<SseEvent> events, {keepAlive, maxIdle, maxLifetime, headers})` renders a `text/event-stream` body as an ordinary `200` with a stream body — no new transport machinery, and `gzip()`/`etag()` pass it through untouched. `SseEvent(data, {event, id, retry})` validates at construction so a forged second event is unrepresentable (CR/LF in `event`/`id`, NUL in `id`, negative `retry` all throw). `maxIdle` fires when the application stops producing (a `keepAlive` comment deliberately does not reset it); `maxLifetime` is an absolute cap that fires even under backpressure; either expiry ends the stream on a clean event boundary, and every timer and the source subscription tear down on completion, error, disconnect, abort, or expiry — whichever first.

A WebSocket handshake is a plain `GET` whose handler returns `Response.upgrade(onConnected, {subprotocol, maxIdle, maxLifetime})`. Because the intent to upgrade is a returned value, every middleware composes in front of it — a security gate answers 401 and the `Upgrade` is never constructed. `onConnected` receives a transport-neutral `UpgradedChannel` (`messages`, `send`, `close`, `done`; text frames are `String`, binary `List<int>`). A declared `subprotocol` must have been offered by the client or the handshake fails; a non-upgrade request to an upgrade route gets 426. `maxIdle` resets only on an inbound frame (a `send` proves nothing about the peer), and either bound's expiry — like graceful shutdown — closes with code 1001.

## serve, lifecycle, and Log

`app.serve(boot, {port: 8080, isolates: 1, transport, maxBodyBytes: 1 << 20})` compiles the trie and binds the H1 transport. `boot` runs once per isolate — the signature makes "boots N times" visible, and every isolate owns and later closes its own env. When `E` implements `HasLog`, `c.log` and access logs flow through it (with `reqId` and `route` baked in); when it implements `Disposable`, `Server.shutdown({grace})` (default 30s) closes it after draining in-flight work. A failed worker spawn tears down what already started rather than leaking a bound socket. `StdoutLog` writes one JSON line per event through a bounded backlog (8 MiB default) over a non-blocking sink: a stalled log collector costs the oldest lines — dropped and honestly reported in-band on the next successful drain — never the server.

## Testing without sockets

`package:keta/test.dart` (a separate import, not re-exported by `keta.dart`) ships `TestClient(app, env)` — the full pipeline against an in-memory request, with `get/post/put/delete/patch/head/options` returning a `TestResponse` (`status`, `headers`, `text()`, `json()`) and `connect(path)` returning a `TestUpgrade` — either an in-process `TestSocket` when the route upgraded or the `rejection` response the pipeline produced instead. `testContext(env, ...)` builds a `Context` for a single handler, and `testBothModes` runs one expectation against both the synchronous-throw and rejected-Future failure shapes.

## Deliberately out of scope

Judged absences, not TODOs — the [root README](../../README.md#deliberately-out-of-scope-for-v01) records them for v0.1: static file serving, HTTP/2 and HTTP/3 transports (only the `Transport` seam exists here), session stores (the cookie primitives above are in core; stores on top of them are not), template engines, content negotiation (keta is JSON-first), and runtime configuration reload. Within this package the source records its own: no 429 `KetaException`, no process-wide admission coordination, and no timer or background work the caller did not opt into.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| both syntaxes route, match precedence, middleware ordering, header validation, query/header accessors | `test/keta_test.dart` |
| verb registration, 405 + `Allow`, typed capture coercion, `App.routes`, fail-fast on bad arguments | `test/app_test.dart` |
| `Key` store, `c.param` coercion and 400s, transport `closed` → `c.aborted` | `test/context_test.dart` |
| body limit 413 and bad-JSON 400 sticky across re-reads; caching; stream consumable once | `test/request_body_test.dart` |
| cookie parsing (malformed pairs, duplicates) and `SetCookie` rendering + injection guards | `test/cookie_test.dart` |
| `recover()`: incidents vs expected outcomes, operator-only `detail` logged, never leaked | `test/recover_test.dart` |
| `accessLog()` honesty markers, bounded `route` field, emit-then-rethrow | `test/access_log_test.dart` |
| `cors()` preflight and `Vary: Origin` union | `test/cors_test.dart` |
| `etag()`/`gzip()`: 304 semantics, negotiation, threshold, Vary union, composition, framing | `test/etag_gzip_test.dart` |
| `rateLimit` bucket (burst, refill, exemption, honest `Retry-After`, memory bound); `concurrencyLimit` admit/refuse/release with no leaked slot | `test/admission_test.dart` |
| `timeout()` 504 + `c.aborted`, late-handler warning, sync results pass through untimed | `test/timeout_test.dart` |
| SSE wire rendering, field validation, keep-alive, passthrough, cancellation, `maxIdle`/`maxLifetime` | `test/sse_test.dart` |
| upgrade handshake/echo/close, security gate, 426, shutdown 1001, `maxIdle`/`maxLifetime`, upgrade surviving middleware rebuilds | `test/websocket_test.dart` |
| strict `traceparent` parsing; `tracing()` populates `traceKey` or leaves it unset | `test/trace_context_test.dart`, `test/tracing_test.dart` |
| H1 framing, oversized-body defense, disconnect detection, graceful shutdown grace | `test/h1_transport_test.dart` |
| survives header injection, erroring body streams, truncated chunked bodies, hung handlers | `test/chaos_test.dart` |
| single-process serve end-to-end and env disposal; multi-isolate serve and no-leak spawn failure | `test/serve_test.dart`, `test/serve_isolates_test.dart` |
| bounded log backlog, oldest-first eviction, honest dropped-count reporting | `test/log_test.dart` |
| data-shaped path form (`List<Segment>`) binds, reads via `c.param`, unbounded arity | `test/data_path_test.dart` |
