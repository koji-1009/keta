# keta_bus

A minimal publish/subscribe seam for keta's realtime features (SSE, WebSocket). A `Bus` carries JSON messages from a `publish(topic, message)` to every `subscribe(topic)` stream. It owns exactly one idea — fan a message out to whoever is listening, now — and nothing more: no queue, no broker, no schema. It does not depend on keta core, keta core does not know about it, and it pulls in zero third-party packages (SDK only).

The problem it solves: an in-process `StreamController.broadcast()` reaches only the isolate it lives in. keta's `serve(isolates: n)` runs request handlers across worker isolates, so a message published while handling a request on one isolate never reaches a subscriber parked on another. `IsolateBus` closes that gap for a single process.

## Delivery guarantee: at-most-once

Every `Bus` delivers **at-most-once**, exactly like a broadcast `Stream`. A published message reaches the subscribers that are listening at the instant of publish, and no others. Concretely:

- A message published to a topic with **no live listener is dropped**.
- A subscriber that **starts listening later never sees earlier messages**.
- There is no acknowledgement and no redelivery — a delivery is made once, or not at all.

**Out of scope, by design** (judged absences, not TODOs): replay / history, persistence, at-least-once or exactly-once delivery, dead-letter handling, and durable subscriptions. A `Bus` is a live fan-out, not a message store. It is also **not** a cross-machine bus: there is no Redis / NATS / PostgreSQL-`LISTEN` adapter, and none is planned here — the interface is small enough that one could be written as a separate package, but that is future work, not a gap in this one.

## Messages are canonical JSON values

A message is a canonical JSON value — `null`, `bool`, `num`, `String`, a `List` of JSON values, or a `Map` with `String` keys and JSON values (the `Object?` model keta already uses for JSON bodies). This is precisely the shape that survives an isolate boundary, so **the same contract holds for `InMemoryBus` and `IsolateBus`** — code written against one runs unchanged against the other. Publishing a non-JSON value (a `Map` with non-string keys, or any other object) throws `ArgumentError` at the `publish` call, naming the offending path (e.g. `message.user[2]`). A non-finite number — `NaN`, `Infinity`, or `-Infinity` — is rejected the same way: `jsonEncode` throws on it, so the bus accepts exactly what `jsonEncode` can serialize and the "canonical JSON" promise stays true. The check is structural, not a `jsonEncode` round-trip. Enforcing it in `InMemoryBus` too means the single-isolate seam cannot silently accept something the multi-isolate one would reject.

## Topics

A topic is a **non-empty `String`**, otherwise opaque. There is no hierarchy and no wildcard matching — a subscriber sees exactly the topic it named. An empty topic throws `ArgumentError` on both `publish` and `subscribe`.

## The two implementations

### `InMemoryBus` — one isolate

Broadcast, at-most-once, within a single isolate. The seam for tests and single-isolate servers. Safe to `publish` from inside a subscriber callback (ordinary broadcast-`Stream` reentrancy).

```dart
final bus = InMemoryBus();
final sub = bus.subscribe('room:42').listen(print);
bus.publish('room:42', {'text': 'hi'});   // -> {text: hi}
await bus.close();                         // sub's stream ends
```

### `IsolateBus` — the worker isolates of one process

One isolate holds the **hub** (`IsolateBus.hub()`); every other isolate holds a **connection** (`IsolateBus.connect(port)`) attached to the hub over a `SendPort`. A message published in any connected isolate reaches subscribers in **every** connected isolate, still at-most-once.

The hub fans every message out to every connection; each isolate filters locally to its own subscribers. There is **no subscription-registration protocol** — this keeps the wiring trivial, at the cost of sending a message to an isolate even when it has no subscriber for that topic (an accepted trade for a single-process, few-isolates bus).

## Multi-isolate wiring sketch

The hub is created and closed by the **application's boot code** (keta_bus does not touch `Env`), *outside* any `Env`, because it outlives every isolate's `Env`. Each isolate — **including isolate 0**, the one `serve` is called from — attaches as its own connection; the connection is the `Bus` an `Env` owns and closes. The shape mirrors keta's own `serve(isolates: n)` handshake — a `SendPort` handed to each worker at spawn:

```dart
// Boot code (before serve) — create the hub outside any Env, capture its port.
final hub = IsolateBus.hub();
final SendPort busPort = hub.connectPort;   // SendPort-transferable to workers

// serve runs `boot` in every isolate it owns, isolate 0 included. Each boot
// attaches its own connection — the Bus that isolate's Env holds:
Future<Env> boot() async => Env(bus: IsolateBus.connect(busPort), /* ... */);
final server = await app.serve(boot, port: port, isolates: n);

// Each Env closes its OWN connection on shutdown. If Env implements keta's
// Disposable, close the connection from Env.close() — the same Env-owned
// lifecycle keta_otel's exporter uses. Server.shutdown() drives those closes.
await server.shutdown();

// The hub belongs to no Env — it was created here, before any isolate booted —
// so the boot code closes it after the servers stop. In an orderly shutdown
// every connection has already detached; this closes the hub itself and tells
// any connection that somehow missed its own close to terminate too.
await hub.close();
```

Isolate 0 is **not** special: it connects like every worker rather than using the hub directly as its `Bus`. This keeps one rule — every `Env` owns a connection, the hub is owned by the boot code — instead of a main-isolate exception. The shipped register example (`examples/register`) is wired exactly this way.

## Lifecycle

`close()` is idempotent. Closing a bus ends its active subscription streams (they emit done) and makes later `publish` / `subscribe` throw `StateError` — using a closed bus is a programming error, not a droppable message.

For `IsolateBus`:

- **Closing the hub** tells every live connection to terminate: their subscription streams close and each connection becomes closed.
- **Closing a connection** detaches it from the hub gracefully (the hub drops its port at once) and ends its own streams. This is the supported way to leave the bus, and it is what an orderly `serve` shutdown does.
- A connection whose isolate dies **abruptly** (killed or crashed) is **not detected** — Dart delivers no error for a `SendPort` whose isolate is gone. The hub keeps the dead connection's port and every fan-out still (harmlessly) sends to it: a no-op that neither errors nor delivers. keta_bus ships **no keepalive/liveness protocol** (judged absence); graceful `close()` is how a connection is meant to leave. What *is* detected: graceful detach and hub-initiated close. What *is not*: crash/kill.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| fan-out to every subscriber, topic isolation, reentrant publish | `test/in_memory_bus_test.dart` |
| at-most-once: no live listener drops; late subscriber sees nothing earlier | `test/in_memory_bus_test.dart` |
| a topic's controller is reclaimed at zero listeners (no unbounded growth over a client-driven topic namespace); resubscribe recreates it; a deliver racing removal is a safe no-op drop; two subscribers keep the topic while one stays | `test/local_delivery_test.dart`, `test/in_memory_bus_test.dart`, `test/isolate_bus_test.dart` |
| close ends streams; publish/subscribe after close throw; idempotent | `test/in_memory_bus_test.dart`, `test/isolate_bus_test.dart` |
| non-empty topic rule, on publish and subscribe, both implementations | `test/topic_rules_test.dart` |
| JSON-value constraint enforced identically by both, with path in the error; a non-finite number (NaN / ±Infinity) is rejected so the bus accepts exactly what `jsonEncode` can serialize | `test/json_value_test.dart` |
| cross-isolate fan-out both directions (real spawned isolate) | `test/isolate_bus_test.dart` |
| hub close terminates connections; connection close ends its own streams | `test/isolate_bus_test.dart` |
| a killed connection is not detected but does not break the hub | `test/isolate_bus_test.dart` |
| `connectPort` is hub-only (a connection throws) | `test/topic_rules_test.dart` |
| a publish that fans out before a connection's attach has reached the hub is dropped for that connection, not buffered | `test/isolate_bus_test.dart` |
| a publish routed toward an already-closed connection is dropped silently, never thrown | `test/isolate_bus_test.dart` |
