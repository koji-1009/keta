/// bin/main.dart's `isolates > 1` path wires the SSE feed onto an
/// `IsolateBus`: this isolate (isolate 0, whichever isolate `serve` was
/// called from) creates the hub and hands `Env.connectBus` — the boot closure
/// `serve` invokes identically in every isolate it owns — nothing but the
/// hub's `SendPort`, because that is the one piece of hub state that is
/// actually sendable across an `Isolate.spawn`. See lib/env.dart's `boot`/
/// `connectBus` doc and bin/main.dart's comment for the full shape.
///
/// What this test proves: a message published from a REAL second isolate,
/// reached only through that captured `SendPort`, is rendered by
/// `userEventsStream` (lib/events.dart) — the exact function `/users/events`
/// calls — as the SSE event a subscriber in THIS isolate receives. That is
/// the multi-isolate fan-out claim this example's README makes, exercised at
/// the level `Env`/`events.dart` actually operate at.
///
/// What this test does NOT cover: a full `serve(isolates: n)` server accepting
/// real HTTP connections on two different worker isolates. That is
/// deliberately not attempted here — which isolate's H1 listener accepts a
/// given client connection is an OS/transport scheduling detail this test has
/// no way to pin, so an HTTP-level version of this test would be flaky by
/// construction (the write and the SSE subscribe would need to land on
/// different isolates to prove anything, and nothing forces that). The
/// component-level proof above is the honest substitute: it exercises the
/// real `IsolateBus.hub()`/`connectBus` wiring bin/main.dart uses, across a
/// real spawned isolate, without needing to control HTTP routing across
/// isolates to do it.
@TestOn('vm')
library;

import 'dart:isolate';

import 'package:keta_bus/keta_bus.dart';
import 'package:keta_register_example/events.dart';
import 'package:test/test.dart';

/// Runs in a freshly spawned isolate: attaches to the hub at [busPort] —
/// exactly what `Env.connectBus` does — and publishes one `users` event, the
/// same shape a write handler publishes in lib/routes.dart.
void _publishFromWorkerIsolate(SendPort busPort) {
  final bus = IsolateBus.connect(busPort);
  bus.publish(usersTopic, {'kind': 'created', 'id': 'cross-isolate-1'});
}

void main() {
  test('userEventsStream renders a message published from a real second '
      'isolate, reached only through the hub SendPort', () async {
    final hub = IsolateBus.hub();
    addTearDown(hub.close);

    // Subscribe before spawning: a Bus delivers at-most-once with no
    // replay (see keta_bus's README), so a subscriber that started
    // listening after the publish would simply never see it — this is not
    // a race to win, it is the ordering the whole feed depends on.
    final firstEvent = userEventsStream(hub).first;

    await Isolate.spawn(_publishFromWorkerIsolate, hub.connectPort);

    final event = await firstEvent.timeout(const Duration(seconds: 5));
    expect(event.event, 'created');
    expect(event.data, contains('"id":"cross-isolate-1"'));
  });

  test('InMemoryBus and IsolateBus — the two Bus implementations Env.boot and '
      'Env.connectBus each choose between — both satisfy the same contract '
      'userEventsStream relies on', () async {
    // Exercises the two Bus implementations directly, NOT through Env.boot/
    // Env.connectBus themselves (those also open a real SqliteDb and apply
    // migrations, which this test has no need to drag in). Not a duplicate
    // of keta_bus's own suite (which already proves InMemoryBus and
    // IsolateBus behave identically) — this pins that THIS example's
    // usersTopic/userEventsStream plumbing works unchanged against either
    // seam, which is the thing that could actually regress here.
    final inMemory = InMemoryBus();
    addTearDown(inMemory.close);
    final viaInMemory = userEventsStream(inMemory).first;
    inMemory.publish(usersTopic, {'kind': 'deleted', 'id': 'x'});
    expect((await viaInMemory).event, 'deleted');

    final hub = IsolateBus.hub();
    addTearDown(hub.close);
    // Subscribe on the hub itself before anything publishes — mirrors
    // keta_bus's README note that "the hub instance is itself a working
    // Bus for the main isolate's own subscribers". Publishing FROM a
    // connection TO the hub needs no attach handshake (see
    // IsolateBus._WorkerBus.publish), so this direction has nothing to
    // race, unlike hub-to-connection fan-out.
    final viaHub = userEventsStream(hub).first;
    final connection = IsolateBus.connect(hub.connectPort);
    addTearDown(connection.close);
    connection.publish(usersTopic, {'kind': 'updated', 'id': 'y'});
    expect((await viaHub).event, 'updated');
  });
}
