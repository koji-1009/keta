import 'package:keta/keta.dart';
import 'package:keta_otel/keta_otel.dart';

import 'env.dart';

/// The request-store key the per-`buildApp` metrics registry travels under.
///
/// Scoped per `buildApp`, not a top-level global — the change from what this
/// file used to hold. A single global registry is shared across every
/// `buildApp()` in one isolate: two apps (every test that builds one, and any
/// multi-app host) would count into the SAME registry, so one test's requests
/// leak into the next's assertions and a real multi-tenant isolate conflates
/// tenants. examples/register scopes its registry the same way — a `buildApp`
/// local captured by the handlers that need it.
///
/// The wrinkle keta_files adds: `routes/metrics.dart` is a *static* `exported`
/// value, so it cannot capture a `buildApp` local the way register's inline
/// `metricsHandler(metrics)` does. Its only channel to the app is its [Context]
/// — so the registry is handed to it there, by [provideMetrics], and read back
/// with this [Key]. Same per-buildApp scoping, reached through the one door a
/// file-routed handler has.
final metricsRegistryKey = Key<MetricsRegistry>('metricsRegistry');

/// Publishes [registry] into every request's store, so `routes/metrics.dart`
/// reads the very registry `otel(metrics: registry)` records into. A single
/// `c.set`, so it cannot throw and may sit anywhere below `recover()`.
Middleware<Env> provideMetrics(MetricsRegistry registry) => (c, next) {
  c.set(metricsRegistryKey, registry);
  return next(c);
};
