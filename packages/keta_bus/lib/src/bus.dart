library;

/// A publish/subscribe seam: messages published to a topic are delivered to the
/// subscribers listening on that topic, with **at-most-once** delivery.
///
/// ## Delivery guarantee
///
/// At-most-once, identical to a broadcast [Stream]: a published message reaches
/// exactly the subscribers whose streams are being listened to at the moment of
/// publish. A message published to a topic with no live listener is dropped. A
/// subscriber that starts listening later never sees earlier messages. There is
/// no buffering, replay, acknowledgement, or redelivery — a delivery is either
/// made once or not at all.
///
/// ## Messages
///
/// A message is a **canonical JSON value**: `null`, [bool], [num], [String],
/// a [List] of JSON values, or a [Map] with [String] keys and JSON values —
/// the same `Object?` model keta uses for JSON bodies. This is the shape that
/// survives an isolate boundary, so the same contract holds for every
/// implementation. Publishing a non-JSON value (a [Map] with non-string keys,
/// or any other object) throws [ArgumentError] at the `publish` call — an
/// author mistake is reported at its source, not swallowed and mis-delivered.
///
/// ## Topics
///
/// A topic is a non-empty [String], otherwise opaque: there is no hierarchy and
/// no wildcard matching (a subscriber sees exactly the topic it named). An
/// empty topic throws [ArgumentError] on both `publish` and `subscribe`.
///
/// ## Lifecycle
///
/// [close] releases the bus. Active subscription streams terminate (they emit
/// done); calling [publish] or [subscribe] afterwards throws [StateError],
/// because using a closed bus is a programming error rather than a droppable
/// message. [close] is idempotent. A bus is meant to be owned by the
/// application's `Env` and closed on server shutdown.
abstract interface class Bus {
  /// Publishes [message] to [topic]. Fire-and-forget: returns immediately and
  /// never blocks on delivery (at-most-once).
  ///
  /// Throws [ArgumentError] if [topic] is empty or [message] is not a canonical
  /// JSON value, and [StateError] if the bus is closed.
  void publish(String topic, Object? message);

  /// A broadcast [Stream] of the messages published to [topic] from the moment
  /// this stream is listened to. Multiple listeners are allowed and each
  /// receives every message delivered while it is listening.
  ///
  /// Throws [ArgumentError] if [topic] is empty and [StateError] if the bus is
  /// closed.
  Stream<Object?> subscribe(String topic);

  /// Releases the bus: active subscription streams close, and later [publish]/
  /// [subscribe] calls throw [StateError]. Idempotent.
  Future<void> close();
}

/// Validates a topic, throwing a descriptive [ArgumentError] on an author
/// mistake. Shared by every [Bus] implementation so the topic contract is one
/// rule in one place.
void checkTopic(String topic) {
  if (topic.isEmpty) {
    throw ArgumentError.value(topic, 'topic', 'topic must not be empty');
  }
}

/// Validates that [value] is a canonical JSON value — `null`, [bool], [num],
/// [String], a [List] of JSON values, or a [Map] with [String] keys and JSON
/// values — throwing [ArgumentError] naming the offending path on the first
/// violation.
///
/// The check is structural (it does not round-trip through `jsonEncode`), which
/// is exactly the invariant that lets a message cross an isolate boundary
/// unchanged. [path] seeds the location reported in the error (e.g.
/// `message.user[2]`).
void checkJsonValue(Object? value, [String path = 'message']) {
  if (value == null || value is bool || value is num || value is String) {
    return;
  }
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      checkJsonValue(value[i], '$path[$i]');
    }
    return;
  }
  if (value is Map) {
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(
          value,
          path,
          'JSON object keys must be String, found ${key.runtimeType} at $path',
        );
      }
      checkJsonValue(entry.value, '$path.$key');
    }
    return;
  }
  throw ArgumentError.value(
    value,
    path,
    'not a JSON value (allowed: null, bool, num, String, List, '
    'Map<String, Object?>) at $path',
  );
}
