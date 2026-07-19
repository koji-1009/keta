# keta_shelf

A bidirectional bridge between keta and `package:shelf`, in exactly two functions: `ketaToShelf` mounts a keta `App` as a `shelf.Handler`, and `shelfToKeta` adapts a `shelf.Handler` into a terminal keta `Handler`. Bodies stream through in both directions, the body limit is enforced on the way in, and what the bridge cannot carry — a raw socket — is refused loudly rather than approximated.

## keta inside shelf: `ketaToShelf`

`ketaToShelf<E>(App<E> app, E env, {int maxBodyBytes = 1 << 20})` compiles the app once at the call — so a route conflict fails fast there, as a `StateError`, not on the first request — and runs the full keta pipeline per request. Incoming shelf header names are lowercased into keta's canonical header shape, and multi-value headers cross via `headersAll`.

The body limit is enforced where keta core always enforces it: at `Context`'s buffering point (`body()` / `bodyBytes()`), so an over-limit body answers 413 with the exact boundary still allowed, while `c.bodyStream()` stays the deliberate unbounded escape hatch. On the way out, `content-length` and `transfer-encoding` are dropped from the keta response so shelf and its server re-frame the body — a stale `content-length` on a stream body would otherwise corrupt the wire.

`c.remoteAddress` is read from shelf_io's `shelf.io.connection_info` context entry when it holds a `dart:io` `HttpConnectionInfo`; a shelf server that does not populate it (or populates it with something else) leaves `c.remoteAddress` as `''`.

Two things do not cross, by design:

- **Protocol upgrades.** A route answering `Response.upgrade` (WebSocket) is rejected with a `StateError` — shelf hands no socket across this bridge, and failing loudly beats mis-framing a bodyless 101 that no client could use. Serve upgrade routes on keta's own transport (`H1Transport`), not through `ketaToShelf`.
- **Client disconnect.** shelf exposes no connection-close signal, so `c.aborted`, `timeout()`'s cooperative-cancellation abort, and any cleanup that watches for the client leaving never fire — a long-poll or SSE-style keta route runs to completion (or its own timeout) even after the peer is long gone. A keta app relying on disconnect detection should be served on its own transport, not mounted here.

## shelf inside keta: `shelfToKeta`

`shelfToKeta<E>(shelf.Handler handler, {int maxBodyBytes = 1 << 20})` returns a terminal `Handler<E>`, so shelf handlers and middleware pipelines run inside a keta route. Request and response bodies are streamed through unbuffered — large uploads and long-lived chunked responses work — with the request stream wrapped in a counting limiter that fails with `PayloadTooLarge` (413) once the cumulative size exceeds `maxBodyBytes` (set it to the app's `maxBodyBytes`). The response body is passed straight through as a stream, `headersAll` keeps multi-value response headers (e.g. several `set-cookie`) faithful, and framing headers are stripped case-insensitively so keta's transport frames the body — a case-mismatched `Content-Length` would otherwise slip through.

The synthesized `shelf.Request` carries no `onHijack` — keta's `Transport` exposes no socket, mirroring the upgrade refusal in the other direction — so `request.hijack()` throws shelf's own `StateError`. It also carries no `context` map: keta has nothing to put there, so shelf middleware that reads `shelf_io`-specific context keys degrades to its fallback behavior instead of throwing.

shelf requires an absolute `requestedUri`; keta routing carries only path and query. An already-absolute URI passes verbatim; otherwise the base is rebuilt from the request's `Host` header, falling back to `localhost`. That header is attacker-controlled and unvalidated by the time it reaches the bridge, so it is treated as hostile input: a value that fails to parse (a stray space, an unterminated IPv6 bracket, an invalid port) or that carries any URI component beyond `host[:port]` — userInfo, path, query, or fragment, as in `Host: evil.com?inject=1` — is rejected as a 400 `BadRequest` rather than reflected into `requestedUri`, and only a URI rebuilt from the validated host and port ever reaches the shelf handler. The query string round-trips exactly, including the distinction between a bare `?` and no `?` at all.

## Both directions, in code

```dart
import 'package:keta/keta.dart';
import 'package:keta_shelf/keta_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;

class Env {}

final app = App<Env>()
  ..get('/hello/:who', (c) => c.json({'hello': c.param<String>('who')}))
  // shelf inside keta: a shelf handler (or piped middleware) as a keta route.
  ..get('/legacy', shelfToKeta((request) => shelf.Response.ok('hi from shelf')));

// keta inside shelf: mount the whole app in an existing shelf stack.
final shelf.Handler mounted = ketaToShelf(app, Env());
```

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| a keta app serves behind shelf (routing, params, 404 pass-through) | `test/bridge_test.dart` |
| a shelf handler runs inside a keta route (status, headers, bodies both ways) | `test/bridge_test.dart` |
| `Response.upgrade` is rejected with a `StateError`, never mis-framed | `test/bridge_test.dart` |
| route conflicts fail at the `ketaToShelf` call, not on first request | `test/bridge_test.dart` |
| shelf request headers are lowercased for keta | `test/bridge_test.dart` |
| framing headers are stripped in both directions, including a case-mismatched `Content-Length`, and stream bodies cross unbuffered | `test/bridge_test.dart` |
| `ketaToShelf` enforces `maxBodyBytes` as 413 at the buffering point, exact boundary allowed; `bodyStream()` stays unbounded | `test/bridge_test.dart` |
| `shelfToKeta`'s limiter streams a body within the limit through and 413s past it | `test/bridge_test.dart` |
| `remoteAddress` comes from `shelf.io.connection_info`, and is `''` when absent or not an `HttpConnectionInfo` | `test/bridge_test.dart` |
| an absolute URI passes verbatim; the query round-trips, including a bare `?` versus none | `test/host_uri_test.dart` |
| a malformed `Host` (unterminated IPv6 bracket, invalid port) is a 400, not a 500 | `test/host_uri_test.dart` |
| a valid `host:port` or bracketed IPv6 `Host` is reflected into `requestedUri` | `test/host_uri_test.dart` |
| a `Host` smuggling a query, userInfo, fragment, or path is rejected as 400, never reflected | `test/host_uri_test.dart` |
