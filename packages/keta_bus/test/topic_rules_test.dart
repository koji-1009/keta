/// Pins the topic-validation posture the Bus contract documents: a topic is a
/// non-empty String, and an empty topic is an author mistake reported at the
/// call site with a descriptive ArgumentError — on both publish and subscribe,
/// for every implementation.
library;

import 'dart:isolate';

import 'package:keta_bus/keta_bus.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryBus', () {
    late InMemoryBus bus;
    setUp(() => bus = InMemoryBus());
    tearDown(() => bus.close());

    test('publish to an empty topic throws ArgumentError', () {
      expect(() => bus.publish('', 'x'), throwsArgumentError);
    });

    test('subscribe to an empty topic throws ArgumentError', () {
      expect(() => bus.subscribe(''), throwsArgumentError);
    });

    test('a non-empty topic is accepted', () {
      expect(() => bus.subscribe(' '), returnsNormally);
      expect(() => bus.publish('a', 'x'), returnsNormally);
    });
  });

  group('IsolateBus hub', () {
    late IsolateBus bus;
    setUp(() => bus = IsolateBus.hub());
    tearDown(() => bus.close());

    test('publish to an empty topic throws ArgumentError', () {
      expect(() => bus.publish('', 'x'), throwsArgumentError);
    });

    test('subscribe to an empty topic throws ArgumentError', () {
      expect(() => bus.subscribe(''), throwsArgumentError);
    });
  });

  group('IsolateBus connection', () {
    late IsolateBus hub;
    late IsolateBus connection;
    setUp(() {
      hub = IsolateBus.hub();
      connection = IsolateBus.connect(hub.connectPort);
    });
    tearDown(() async {
      await connection.close();
      await hub.close();
    });

    test('publish to an empty topic throws ArgumentError', () {
      expect(() => connection.publish('', 'x'), throwsArgumentError);
    });

    test('subscribe to an empty topic throws ArgumentError', () {
      expect(() => connection.subscribe(''), throwsArgumentError);
    });

    test('connectPort on a connection throws StateError', () {
      // Only the hub owns a port to hand out; asking a connection is a bug.
      expect(() => connection.connectPort, throwsStateError);
      // Reference dart:isolate so the SendPort-typed API stays imported.
      expect(hub.connectPort, isA<SendPort>());
    });
  });
}
