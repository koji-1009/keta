/// keta_bus — a minimal publish/subscribe [Bus] for keta.
///
/// A [Bus] carries JSON values from a `publish(topic, message)` to every
/// `subscribe(topic)` stream, with **at-most-once** delivery: a message reaches
/// only the subscribers that are already listening when it is published, and is
/// otherwise dropped (exactly the semantics of a broadcast [Stream]). There is
/// no replay, no persistence, and no at-least-once redelivery — those are out
/// of scope by design, not gaps to fill later (see the package README).
///
/// Two implementations ship:
///
/// * [InMemoryBus] — single isolate. The seam for tests and single-isolate
///   servers.
/// * [IsolateBus] — spans the worker isolates of one process, so a message
///   published in any isolate reaches subscribers in every connected isolate.
///   Built for keta's `serve(isolates: n)`: create the hub in the main isolate
///   and hand each worker the hub's `connectPort`.
///
/// keta_bus does not depend on keta core and keta core does not know about it;
/// wiring a bus into a request `Env` (and closing it on shutdown) is the
/// application's job.
library;

export 'src/bus.dart' show Bus;
export 'src/in_memory_bus.dart' show InMemoryBus;
export 'src/isolate_bus.dart' show IsolateBus;
