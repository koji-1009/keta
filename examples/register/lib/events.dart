import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';

/// The topic user mutations publish to and `/users/events` streams from — the
/// single name that must agree between every `bus.publish` call and the one
/// `bus.subscribe` in [userEventsStream].
///
/// This used to be an in-process `StreamController.broadcast()` (`UserEvents`,
/// scoped per `buildApp` so two apps in one isolate never cross-talked). That
/// reached only the isolate it lived in — a message published while handling a
/// request on one of `serve(isolates: n)`'s worker isolates never reached a
/// subscriber parked on another. A [Bus] (keta_bus) closes that gap: the same
/// `publish`/`subscribe` calls below work unchanged whether `Env.bus` is an
/// [InMemoryBus] (single isolate) or an [IsolateBus] connection (`serve
/// (isolates: n)`) — see lib/env.dart and bin/main.dart for which one a given
/// run gets. The bus is Env-owned and closed on shutdown, not a `buildApp`
/// local, because it must be reachable from `bin/main.dart`'s isolate-wiring
/// code too.
const usersTopic = 'users';

/// Renders [usersTopic]'s messages as the SSE feed `/users/events` streams:
/// each bus message is already the `{"kind", "id"}` JSON object a write
/// handler published (see lib/routes.dart's create/update/delete handlers), so
/// this only has to pick `kind` back out as the SSE `event:` name — the same
/// projection the old `UserEvents.publish` used to do inline.
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
