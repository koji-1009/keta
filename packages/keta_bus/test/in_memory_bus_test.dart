/// Pins InMemoryBus's core contract: broadcast fan-out to every subscriber,
/// topic isolation, at-most-once delivery (no live listener → dropped, a late
/// subscriber sees nothing published before it listened), reentrant publish
/// from inside a callback, and close semantics (streams end; publish/subscribe
/// after close throw).
library;

import 'dart:async';

import 'package:keta_bus/keta_bus.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryBus bus;

  setUp(() => bus = InMemoryBus());
  tearDown(() => bus.close());

  test('a subscriber receives messages published to its topic', () async {
    final received = <Object?>[];
    final sub = bus.subscribe('greetings').listen(received.add);
    addTearDown(sub.cancel);

    bus.publish('greetings', 'hello');
    bus.publish('greetings', {'n': 1});
    await pumpEventQueue();

    expect(received, [
      'hello',
      {'n': 1},
    ]);
  });

  test('every subscriber on a topic receives each message', () async {
    final a = <Object?>[];
    final b = <Object?>[];
    final subA = bus.subscribe('t').listen(a.add);
    final subB = bus.subscribe('t').listen(b.add);
    addTearDown(subA.cancel);
    addTearDown(subB.cancel);

    bus.publish('t', 42);
    await pumpEventQueue();

    expect(a, [42]);
    expect(b, [42]);
  });

  test('topics are isolated: a subscriber sees only its own topic', () async {
    final onT = <Object?>[];
    final sub = bus.subscribe('t').listen(onT.add);
    addTearDown(sub.cancel);

    bus.publish('other', 'nope');
    bus.publish('t', 'yes');
    await pumpEventQueue();

    expect(onT, ['yes']);
  });

  test('no live listener → the message is dropped (at-most-once)', () async {
    // Subscribe, then cancel, so a controller exists but has no listener.
    final received = <Object?>[];
    final sub = bus.subscribe('t').listen(received.add);
    await sub.cancel();

    bus.publish('t', 'into the void');
    await pumpEventQueue();

    expect(received, isEmpty);
  });

  test('re-subscribing a reclaimed topic still delivers', () async {
    // After the last listener cancels, the topic's controller is reclaimed;
    // subscribing again must recreate it and deliver normally (the leak fix
    // must not break the resubscribe path).
    final first = bus.subscribe('t').listen((_) {});
    await first.cancel();

    final received = <Object?>[];
    final second = bus.subscribe('t').listen(received.add);
    addTearDown(second.cancel);

    bus.publish('t', 'after-reclaim');
    await pumpEventQueue();

    expect(received, ['after-reclaim']);
  });

  test('one of two subscribers cancelling leaves the other live', () async {
    final a = <Object?>[];
    final b = <Object?>[];
    final subA = bus.subscribe('t').listen(a.add);
    final subB = bus.subscribe('t').listen(b.add);
    addTearDown(subB.cancel);

    await subA.cancel();

    bus.publish('t', 'still-here');
    await pumpEventQueue();

    expect(a, isEmpty);
    expect(b, ['still-here']);
  });

  test('a late subscriber never sees earlier messages', () async {
    bus.publish('t', 'before');
    final received = <Object?>[];
    final sub = bus.subscribe('t').listen(received.add);
    addTearDown(sub.cancel);

    bus.publish('t', 'after');
    await pumpEventQueue();

    expect(received, ['after']);
  });

  test('publishing from inside a subscriber callback is safe', () async {
    final received = <Object?>[];
    late StreamSubscription<Object?> sub;
    sub = bus.subscribe('t').listen((m) {
      received.add(m);
      if (m == 'first') bus.publish('t', 'second');
    });
    addTearDown(sub.cancel);

    bus.publish('t', 'first');
    await pumpEventQueue();

    expect(received, ['first', 'second']);
  });

  test('close ends active subscription streams', () async {
    var done = false;
    final sub = bus.subscribe('t').listen((_) {}, onDone: () => done = true);
    addTearDown(sub.cancel);

    await bus.close();
    await pumpEventQueue();

    expect(done, isTrue);
  });

  test('publish after close throws StateError', () async {
    await bus.close();
    expect(() => bus.publish('t', 'x'), throwsStateError);
  });

  test('subscribe after close throws StateError', () async {
    await bus.close();
    expect(() => bus.subscribe('t'), throwsStateError);
  });

  test('close is idempotent', () async {
    await bus.close();
    await expectLater(bus.close(), completes);
  });
}
