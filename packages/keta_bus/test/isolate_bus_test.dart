/// Pins IsolateBus's cross-isolate contract. Two layers: the wiring protocol,
/// exercised with a hub and a connection in one isolate (fast, deterministic
/// with pumped event queues); and the real thing, spawning an actual worker
/// isolate to prove fan-out in both directions over SendPorts. Also pins close
/// semantics (hub close terminates connections; connection close ends its own
/// streams) and the honest limit on death detection: a killed connection is not
/// detected, but it must not break the hub.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:keta_bus/keta_bus.dart';
import 'package:test/test.dart';

void main() {
  group('one isolate: protocol', () {
    late IsolateBus hub;
    late IsolateBus connection;

    setUp(() async {
      hub = IsolateBus.hub();
      connection = IsolateBus.connect(hub.connectPort);
      // Let the connection's attach reach the hub before any publish.
      await pumpEventQueue();
    });
    tearDown(() async {
      await connection.close();
      await hub.close();
    });

    test('hub publish reaches hub and connection subscribers', () async {
      final onHub = <Object?>[];
      final onConnection = <Object?>[];
      final s1 = hub.subscribe('t').listen(onHub.add);
      final s2 = connection.subscribe('t').listen(onConnection.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);
      await pumpEventQueue();

      hub.publish('t', 'x');
      await pumpEventQueue();

      expect(onHub, ['x']);
      expect(onConnection, ['x']);
    });

    test(
      'connection publish reaches hub and connection subscribers (echo)',
      () async {
        final onHub = <Object?>[];
        final onConnection = <Object?>[];
        final s1 = hub.subscribe('t').listen(onHub.add);
        final s2 = connection.subscribe('t').listen(onConnection.add);
        addTearDown(s1.cancel);
        addTearDown(s2.cancel);
        await pumpEventQueue();

        connection.publish('t', 'y');
        await pumpEventQueue();

        expect(onHub, ['y']);
        expect(onConnection, ['y']);
      },
    );

    test('topics stay isolated across the boundary', () async {
      final onConnection = <Object?>[];
      final sub = connection.subscribe('wanted').listen(onConnection.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      hub.publish('other', 'no');
      hub.publish('wanted', 'yes');
      await pumpEventQueue();

      expect(onConnection, ['yes']);
    });

    test('hub close terminates connection subscriptions', () async {
      var done = false;
      final sub = connection
          .subscribe('t')
          .listen((_) {}, onDone: () => done = true);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await hub.close();
      await pumpEventQueue();

      expect(done, isTrue);
      expect(() => connection.publish('t', 'x'), throwsStateError);
    });
  });

  group('one isolate: connection lifecycle', () {
    test('connection close ends its own subscription streams', () async {
      final hub = IsolateBus.hub();
      final connection = IsolateBus.connect(hub.connectPort);
      addTearDown(hub.close);
      await pumpEventQueue();

      var done = false;
      final sub = connection
          .subscribe('t')
          .listen((_) {}, onDone: () => done = true);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await connection.close();
      await pumpEventQueue();

      expect(done, isTrue);
    });

    test('publish/subscribe after connection close throw StateError', () async {
      final hub = IsolateBus.hub();
      final connection = IsolateBus.connect(hub.connectPort);
      addTearDown(hub.close);
      await pumpEventQueue();

      await connection.close();

      expect(() => connection.publish('t', 'x'), throwsStateError);
      expect(() => connection.subscribe('t'), throwsStateError);
    });

    test('hub publish after close throws StateError', () async {
      final hub = IsolateBus.hub();
      await hub.close();
      expect(() => hub.publish('t', 'x'), throwsStateError);
    });
  });

  group('real isolates', () {
    test('fan-out reaches both directions across a spawned isolate', () async {
      final hub = IsolateBus.hub();
      addTearDown(hub.close);

      final mainReceived = <Object?>[];
      final sub = hub.subscribe('events').listen(mainReceived.add);
      addTearDown(sub.cancel);

      final report = ReceivePort();
      final workerReceived = <Object?>[];
      final ready = Completer<void>();
      report.listen((msg) {
        switch (msg) {
          case ('recv', final Object? m):
            workerReceived.add(m);
          case ('ready',):
            if (!ready.isCompleted) ready.complete();
          default:
        }
      });

      final isolate = await Isolate.spawn(_echoWorker, (
        hub.connectPort,
        report.sendPort,
      ));
      addTearDown(() {
        isolate.kill(priority: Isolate.immediate);
        report.close();
      });

      // The worker signals ready only after receiving the echo of its own
      // publish — proof the hub has processed its attach.
      await ready.future.timeout(const Duration(seconds: 20));

      hub.publish('events', 'main-hello');

      await _until(
        () =>
            mainReceived.contains('main-hello') &&
            workerReceived.contains('main-hello'),
        const Duration(seconds: 20),
      );

      // Worker→hub delivery (worker-hello) and hub→worker delivery (main-hello).
      expect(
        mainReceived,
        containsAll(<Object?>['worker-hello', 'main-hello']),
      );
      expect(
        workerReceived,
        containsAll(<Object?>['worker-hello', 'main-hello']),
      );
    });

    test(
      'a killed connection does not break the hub (death not detected)',
      () async {
        final hub = IsolateBus.hub();
        addTearDown(hub.close);

        final report = ReceivePort();
        final ready = Completer<void>();
        report.listen((msg) {
          if (msg == 'ready' && !ready.isCompleted) ready.complete();
        });

        final isolate = await Isolate.spawn(_readyWorker, (
          hub.connectPort,
          report.sendPort,
        ));
        addTearDown(report.close);

        await ready.future.timeout(const Duration(seconds: 20));

        // Kill abruptly: the worker's SendPort lingers in the hub's set, and Dart
        // surfaces no error for sending to it — so the hub keeps working.
        isolate.kill(priority: Isolate.immediate);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final mainReceived = <Object?>[];
        final sub = hub.subscribe('events').listen(mainReceived.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();

        expect(() => hub.publish('events', 'after-death'), returnsNormally);
        await _until(
          () => mainReceived.contains('after-death'),
          const Duration(seconds: 10),
        );
        expect(mainReceived, ['after-death']);
      },
    );
  });
}

/// Runs in a spawned isolate: connects, echoes every 'events' message it sees
/// back to [report], and announces 'ready' once it has received the echo of its
/// own first publish (which proves its attach was processed by the hub).
Future<void> _echoWorker((SendPort, SendPort) args) async {
  final (connectPort, report) = args;
  final bus = IsolateBus.connect(connectPort);
  var announced = false;
  bus.subscribe('events').listen((m) {
    report.send(('recv', m));
    if (m == 'worker-hello' && !announced) {
      announced = true;
      report.send(const ('ready',));
    }
  });
  bus.publish('events', 'worker-hello');
}

/// Runs in a spawned isolate: connects and reports 'ready' once its attach is
/// confirmed (via the echo of its own publish), then stays alive to be killed.
Future<void> _readyWorker((SendPort, SendPort) args) async {
  final (connectPort, report) = args;
  final bus = IsolateBus.connect(connectPort);
  bus.subscribe('ping').listen((_) => report.send('ready'));
  bus.publish('ping', 1);
}

/// Polls [condition] until true or [timeout] elapses (for real cross-isolate
/// delivery, which pumping the local event queue cannot resolve).
Future<void> _until(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
