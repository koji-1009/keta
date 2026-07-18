# keta_websocket_example

A small, focused example: the WebSocket handshake as an ordinary `GET` whose
handler returns `Response.upgrade(...)` — upgrade as a value, not a special
verb or a hijacked socket — gated by a bearer `SecurityPolicy` so an
unauthenticated handshake is refused with a plain 401 before any switch
happens. Kept separate from `../register`'s CRUD app so this one idea stands
on its own; the SSE companion to this feed lives there instead
(`/users/events`).

`lib/app.dart`'s `buildApp` runs a deliberately minimal stack — `accessLog`,
`recover`, `enforceSecurity`, and nothing else, no `cors()`. That is a focus
choice, not a workaround: keta's response-rebuilding middleware (`cors`,
`etag`, `gzip`) rebuild through `Response.copyWith`, which carries an
upgrade's `Upgrade` field through untouched, so a handshake composes behind
them unchanged — this example just stays small enough that the one idea it
exists to show (the security gate composing in front of an upgrade) is not
competing with anything else on the stack.

## Run

```bash
dart run bin/main.dart              # serves on :8080
```

## Try it

`GET /ws/echo` is the handshake. A bare `curl` cannot speak the WebSocket
protocol past it, but that is enough to see the gate refuse before any switch
happens — no partial upgrade, just an ordinary 401:

```bash
curl -i localhost:8080/ws/echo                                  # 401, refused before the upgrade
curl -i localhost:8080/ws/echo -H 'authorization: Bearer nope'  # 401, a bad token fails closed too
```

For the real upgrade, a WebSocket-aware client is needed, e.g.
[`wscat`](https://github.com/websockets/wscat):

```bash
wscat -c ws://localhost:8080/ws/echo -H 'authorization: Bearer t-ok'
# connected (101); the server greets with "hello ada", then echoes every
# frame sent back
```

Demo token: `t-ok` → `ada` (`lib/app.dart`'s `_tokens`).

## Tested without a socket

`test/websocket_test.dart` exercises the same handshake twice: once through
`TestClient.connect()` — no socket, no port, so the gate-before-switch
composition and the 401 refusal are provable in-process — and once more over
a real `dart:io` `WebSocket`, to prove the bundled H1 transport actually
performs the 101 switch and frames messages, not just that the in-process
model of it does.

## OpenAPI

There is no separate `tool/openapi.dart` here — `lib/app.dart`'s
`buildOpenApi()` is the whole of it, built from the same `buildApp()` the
runtime serves, so the document and the gate cannot silently disagree.
The handshake documents as a `RouteDoc.upgrade(upgrade: SwitchingProtocols())`
— parallel to `Success` rather than a case of it, since a 101 is not a 2xx —
with `security: [bearer]` declared, so the automatic 401 the refusal produces
reaches the document too. `test/websocket_test.dart`'s last test asserts
exactly that.

## Layout

- `lib/app.dart` — `Env`, the bearer `SecurityPolicy`, `buildApp` (the minimal
  stack), `buildOpenApi`
- `bin/main.dart` — serves; connect with `ws://localhost:8080/ws/echo` and an
  `Authorization: Bearer t-ok` header
- `test/websocket_test.dart` — in-process (`TestClient.connect`) and
  real-socket coverage of the upgrade, the 401 refusal, and the OpenAPI shadow
