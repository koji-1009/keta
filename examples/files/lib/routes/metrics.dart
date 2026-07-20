import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/observability.dart';
import 'package:keta_otel/keta_otel.dart';

/// Metrics are not public: apiKey rather than the bearer everything else uses,
/// so the document carries two schemes and the gate honours both.
///
/// The registry is per-buildApp (see observability.dart), not a global this
/// static value could close over. This handler reaches it the only way a
/// file-routed handler can — through the request store that `provideMetrics`
/// filled — and hands it to `metricsHandler` to render. The per-request
/// `metricsHandler` allocation is trivial next to a Prometheus scrape.
final exported = Exported<Env>(
  get: Serve(
    (c) => metricsHandler<Env>(c.get(metricsRegistryKey))(c),
    doc: const RouteDoc(
      success: Success(),
      summary: 'Prometheus metrics',
      security: [apiKey],
    ),
  ),
);
