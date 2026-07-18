library;

import 'bus.dart';
import 'local_delivery.dart';

/// A single-isolate [Bus] with broadcast, at-most-once delivery.
///
/// Publishing to a topic with no live subscriber drops the message; a late
/// subscriber sees only messages published after it starts listening. Safe to
/// [publish] from inside a subscriber callback — that is ordinary broadcast
/// [Stream] reentrancy, and the re-entered message is delivered to listeners in
/// turn.
///
/// This is the single-isolate seam. For delivery across the worker isolates of
/// `serve(isolates: n)`, use [IsolateBus].
final class InMemoryBus implements Bus {
  final LocalDelivery _delivery = LocalDelivery();
  bool _closed = false;

  @override
  void publish(String topic, Object? message) {
    _ensureOpen();
    checkTopic(topic);
    checkJsonValue(message);
    _delivery.deliver(topic, message);
  }

  @override
  Stream<Object?> subscribe(String topic) {
    _ensureOpen();
    checkTopic(topic);
    return _delivery.subscribe(topic);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _delivery.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('InMemoryBus is closed');
    }
  }
}
