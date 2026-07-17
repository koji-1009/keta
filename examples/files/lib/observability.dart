import 'package:keta_otel/keta_otel.dart';

/// The metrics registry, per isolate.
///
/// A top-level final rather than a `buildApp` local, because `routes/metrics.dart`
/// has to reach the very registry `otel` records into, and a route file's only
/// channel to the app is its [Context] — which buildApp's locals are not on.
/// Dart initializes this lazily per isolate, which is exactly what per-isolate
/// metrics means: `serve(isolates: 4)` gets four, each counting its own.
final metrics = MetricsRegistry();
