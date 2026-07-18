import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';

/// This reference only needs a logger — no database — so Env implements just
/// [HasLog]. Auth is orthogonal to persistence.
class Env implements HasLog, Disposable {
  Env(this.log);
  @override
  final Log log;

  /// The cookie-session store: `sid -> role`. keta ships no session store by
  /// design (the same "keta ships no auth" rule that leaves the bearer token
  /// table to the app) — this in-memory `Map` is the app's own state, owned by
  /// `Env` because it must outlive any single request and be shared by every
  /// request the isolate serves. A real app swaps it for Redis or a database
  /// table without touching the verifier or the routes below: the primitives
  /// (`SetCookie`, `c.cookie`) are all keta provides, and they suffice.
  final Map<String, String> sessions = {};

  /// The revocation channel `/me/events` streams from and `logout` publishes
  /// to (see lib/auth.dart) — Env-owned and closed on shutdown, same as
  /// keta_otel's exporter. This example runs single-isolate (`bin/main.dart`
  /// does not pass `isolates:`), so an [InMemoryBus] is the honest choice; see
  /// `../register`'s `Env` for the `IsolateBus` shape a multi-isolate app
  /// would need instead.
  final Bus bus = InMemoryBus();

  static Future<Env> boot() async => Env(StdoutLog());

  @override
  Future<void> close() => bus.close();
}
