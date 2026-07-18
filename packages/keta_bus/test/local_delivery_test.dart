/// Pins the topic-reclaim invariant at its source: LocalDelivery removes a
/// topic's broadcast controller the instant its last listener cancels, so a
/// client-driven topic namespace (one topic per session id) cannot leave dead
/// controllers resident for the life of the process. Also pins the correctness
/// seams the reclaim must not break — a deliver racing removal is a safe no-op
/// drop, a subscribe→cancel→subscribe recreates the topic, two subscribers
/// keep the topic while one stays, onCancel firing synchronously mid-delivery
/// does not corrupt state, and close() still works after topics are reclaimed.
///
/// LocalDelivery is not exported (it is keta_bus's in-isolate core); this test
/// imports the implementation directly to observe [LocalDelivery.activeTopicCount],
/// the one seam a public-API behavioural test cannot see.
library;

import 'dart:async';

import 'package:keta_bus/src/local_delivery.dart';
import 'package:test/test.dart';

void main() {
  late LocalDelivery delivery;
  setUp(() => delivery = LocalDelivery());
  tearDown(() => delivery.close());

  test('a topic is reclaimed once its last listener cancels', () async {
    expect(delivery.activeTopicCount, 0);

    final sub = delivery.subscribe('session:1').listen((_) {});
    expect(delivery.activeTopicCount, 1);

    await sub.cancel();
    expect(
      delivery.activeTopicCount,
      0,
      reason: 'the listener-less controller must not stay resident',
    );
  });

  test('a client-driven namespace does not accumulate controllers', () async {
    // Simulate the shipped auth pattern: one topic per session id, each opened
    // then closed. Without reclaim this grows unbounded.
    for (var i = 0; i < 100; i++) {
      final sub = delivery.subscribe('session:$i').listen((_) {});
      await sub.cancel();
    }
    expect(delivery.activeTopicCount, 0);
  });

  test(
    'two subscribers keep the topic; one cancelling does not reclaim',
    () async {
      final subA = delivery.subscribe('t').listen((_) {});
      final subB = delivery.subscribe('t').listen((_) {});
      expect(delivery.activeTopicCount, 1);

      await subA.cancel();
      expect(
        delivery.activeTopicCount,
        1,
        reason: 'subB is still live — the topic must stay',
      );

      await subB.cancel();
      expect(delivery.activeTopicCount, 0);
    },
  );

  test(
    'subscribe → cancel → subscribe recreates the topic and delivers',
    () async {
      final first = delivery.subscribe('t').listen((_) {});
      await first.cancel();
      expect(delivery.activeTopicCount, 0);

      final received = <Object?>[];
      final second = delivery.subscribe('t').listen(received.add);
      addTearDown(second.cancel);
      expect(delivery.activeTopicCount, 1);

      delivery.deliver('t', 'again');
      await pumpEventQueue();
      expect(received, ['again']);
    },
  );

  test('deliver racing removal is a safe no-op drop', () async {
    final received = <Object?>[];
    final sub = delivery.subscribe('t').listen(received.add);
    await sub.cancel();
    // Topic reclaimed; the controller is gone.
    expect(delivery.activeTopicCount, 0);

    // A publish that lost the race finds no entry and drops silently.
    expect(() => delivery.deliver('t', 'into the void'), returnsNormally);
    await pumpEventQueue();
    expect(received, isEmpty);
    expect(delivery.activeTopicCount, 0);
  });

  test(
    'onCancel firing synchronously mid-delivery does not corrupt state',
    () async {
      // A listener that cancels itself from inside its own callback forces
      // onCancel to run while `deliver` is still delivering. It must neither
      // throw nor leave the topic resident.
      final received = <Object?>[];
      late StreamSubscription<Object?> sub;
      sub = delivery.subscribe('t').listen((m) {
        received.add(m);
        sub.cancel();
      });

      expect(() => delivery.deliver('t', 'once'), returnsNormally);
      await pumpEventQueue();

      expect(received, ['once']);
      expect(delivery.activeTopicCount, 0);
    },
  );

  test('close() completes after topics have been reclaimed', () async {
    final sub = delivery.subscribe('t').listen((_) {});
    await sub.cancel();
    expect(delivery.activeTopicCount, 0);

    // An onCancel that would fire during close finds no matching entry (close
    // clears the map first), so close is a clean no-op over zero controllers.
    await expectLater(delivery.close(), completes);
  });

  test('close() ends live streams and empties the topic map', () async {
    var done = false;
    delivery.subscribe('t').listen((_) {}, onDone: () => done = true);
    expect(delivery.activeTopicCount, 1);

    await delivery.close();
    await pumpEventQueue();

    expect(done, isTrue);
    expect(delivery.activeTopicCount, 0);
  });
}
