import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';

/// The per-app broadcast of user mutations — the source the `/users/events`
/// SSE feed streams to subscribers.
///
/// A `buildApp`-scoped value handed to the handlers that need it, never a
/// top-level global: the write handlers ([publish]) and the SSE route ([stream])
/// must share one instance, but two apps built in one isolate (the ordinary test
/// shape, and any multi-tenant host) must not cross-talk. The metrics registry
/// is scoped the same way and for the same reason.
///
/// The controller is a *broadcast* one on purpose: an SSE feed may have many
/// concurrent `EventSource` subscribers, and one create/update/delete fans out
/// to all of them. A broadcast controller also drops an event when no one is
/// listening rather than buffering it forever — the right default for a live
/// feed, where a client that (re)connects wants "what is happening now", not a
/// replay of everything it missed. Durable delivery would be a log or a queue,
/// which is deliberately not what this is.
class UserEvents {
  final _controller = StreamController<SseEvent>.broadcast();

  /// The live feed. Each subscription is independent, so an SSE client
  /// disconnecting (its `c.sse` body cancelling) tears down only that one
  /// subscription and leaves the controller and every other subscriber intact.
  Stream<SseEvent> get stream => _controller.stream;

  /// Publishes one mutation. [kind] (`created`, `updated`, `deleted`) is the SSE
  /// `event:` name an `EventSource` keys its listener on; the payload is a small
  /// JSON object naming the affected id, so a client learns *what* changed
  /// without the feed having to embed the whole row.
  void publish(String kind, String id) => _controller.add(
    SseEvent(jsonEncode({'kind': kind, 'id': id}), event: kind),
  );
}
