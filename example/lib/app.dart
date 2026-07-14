import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_otel/keta_otel.dart';

import 'env.dart';
import 'routes.dart';

/// Builds the fully-configured application: middleware plus every route. Pure
/// and env-free, so it can build the OpenAPI shadow and be re-run per isolate.
///
/// The middleware stack shows the common cross-cutting concerns: access logging,
/// CORS, request metrics, error recovery, and a transaction per request.
App<Env> buildApp() {
  final metrics = MetricsRegistry();
  final app = App<Env>()
    ..use(accessLog())
    ..use(cors(allowOrigins: const ['*']))
    ..use(otel(metrics: metrics))
    ..use(recover())
    ..use(tx());
  register(app);
  app.get('/metrics', metricsHandler(metrics));
  return app;
}
