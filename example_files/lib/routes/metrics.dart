import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/observability.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

/// Metrics are not public: apiKey rather than the bearer everything else uses,
/// so the document carries two schemes and the gate honours both.
const getDoc = RouteDoc(summary: 'Prometheus metrics', security: [apiKey]);

/// Built once, not per request: metricsHandler closes over the registry, and
/// rebuilding that closure on every scrape would be work for nothing.
final _render = metricsHandler<Env>(metrics);

FutureOr<Response> get(Context<Env> c) => _render(c);
