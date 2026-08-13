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
///
/// A controller is also *reclaimed* the moment its last listener cancels, so a
/// client-driven topic namespace (one topic per session id, say) cannot leave a
/// dead controller resident for the life of the process. The next [subscribe]
/// recreates it. A [deliver] racing that removal is a safe no-op drop —
/// at-most-once means a message with no live listener is correctly dropped.
class LocalDelivery {
  final Map<String, StreamController<Object?>> _topics = {};

  /// The number of topics that currently hold a live controller. Test-only
  /// observability for the reclaim invariant — this class is not exported, so
  /// this getter is not part of keta_bus's public surface.
  int get activeTopicCount => _topics.length;

  /// Delivers [message] to the topic's live listeners, or drops it if the topic
  /// has no controller (never subscribed, or already reclaimed) or no current
  /// listener.
  void deliver(String topic, Object? message) {
    _topics[topic]?.add(message);
  }

  /// The broadcast stream for [topic], creating its controller on first call
  /// (and again after a previous controller was reclaimed at zero listeners).
  Stream<Object?> subscribe(String topic) {
    return _topics.putIfAbsent(topic, () {
      // The identity guard is what makes reclaim safe: a controller that was
      // already replaced must never remove its successor, and an `onCancel`
      // firing during `close()` (which clears the map first) must find no
      // match. `hasListener` covers the two-subscriber case, where `onCancel`
      // fires for one while the other keeps the topic live.
      late final StreamController<Object?> controller;
      controller = StreamController<Object?>.broadcast(
        onCancel: () {
          if (identical(_topics[topic], controller) &&
              !controller.hasListener) {
            _topics.remove(topic);
          }
        },
      );
      return controller;
    }).stream;
  }

  /// Closes every topic controller (active subscription streams emit done).
  Future<void> close() async {
    final controllers = _topics.values.toList();
    _topics.clear();
    for (final controller in controllers) {
      await controller.close();
    }
  }
}
