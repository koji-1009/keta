import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';

/// The topic user mutations publish to and `/users/events` streams from — the
/// single name that must agree between every `bus.publish` call and the one
/// `bus.subscribe` in [userEventsStream].
///
/// A [Bus] (keta_bus) rather than an in-process `StreamController.broadcast()`,
/// which would reach only the isolate it lives in: a message published while
/// handling a request on one of `serve(isolates: n)`'s workers would never reach
/// a subscriber parked on another. The same `publish`/`subscribe` calls below
/// work unchanged whether `Env.bus` is an [InMemoryBus] (single isolate) or an
/// [IsolateBus] connection — see lib/env.dart and bin/main.dart for which one a
/// given run gets. The bus is Env-owned and closed on shutdown, not a `buildApp`
/// local, because `bin/main.dart`'s isolate-wiring code must reach it too.
const usersTopic = 'users';

/// Renders [usersTopic]'s messages as the SSE feed `/users/events` streams:
/// each bus message is already the `{"kind", "id"}` JSON object a write
/// handler published (see lib/routes.dart's create/update/delete handlers), so
/// this only has to pick `kind` back out as the SSE `event:` name.
///
/// A [Bus] delivers at-most-once with no replay (see keta_bus's README): a
/// subscriber that starts listening after a mutation simply does not see it,
/// exactly the "what is happening now, not a backlog" semantics the SSE feed
/// always had.
Stream<SseEvent> userEventsStream(Bus bus) =>
    bus.subscribe(usersTopic).map((raw) {
      final msg = raw as Map<String, Object?>;
      return SseEvent(jsonEncode(msg), event: msg['kind'] as String);
    });
