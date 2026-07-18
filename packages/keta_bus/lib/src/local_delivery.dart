library;

import 'dart:async';

/// The in-isolate delivery core shared by [InMemoryBus] and each isolate's side
/// of [IsolateBus]: one broadcast [StreamController] per subscribed topic.
///
/// Not exported. It carries no validation — callers validate at the public
/// `publish` boundary, so a message that has already been validated once (e.g.
/// forwarded from another isolate) is not re-checked.
///
/// A controller is created lazily on first [subscribe] and never before, so
/// [deliver] to a topic no one has subscribed to has nowhere to go and the
/// message is dropped — the at-most-once rule falling straight out of broadcast
/// [Stream] semantics.
class LocalDelivery {
  final Map<String, StreamController<Object?>> _topics = {};

  /// Delivers [message] to the topic's live listeners, or drops it if the topic
  /// has no controller (never subscribed) or no current listener.
  void deliver(String topic, Object? message) {
    _topics[topic]?.add(message);
  }

  /// The broadcast stream for [topic], creating its controller on first call.
  Stream<Object?> subscribe(String topic) =>
      _topics.putIfAbsent(topic, StreamController<Object?>.broadcast).stream;

  /// Closes every topic controller (active subscription streams emit done).
  Future<void> close() async {
    final controllers = _topics.values.toList();
    _topics.clear();
    for (final controller in controllers) {
      await controller.close();
    }
  }
}
