import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/observability.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

/// Metrics are not public: apiKey rather than the bearer everything else uses,
/// so the document carries two schemes and the gate honours both.
///
/// `final`, not `const` like every other route file: metricsHandler closes over
/// the registry, and a closure is not a constant. Built once here rather than
/// rebuilt on every scrape.
final exported = Exported<Env>(
  get: Serve(
    metricsHandler<Env>(metrics),
    doc: const RouteDoc(summary: 'Prometheus metrics', security: [apiKey]),
  ),
);
