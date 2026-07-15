import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

import 'auth.dart';
import 'env.dart';

// The import and registration lines below are materialized by
// `dart run keta_files:sync` from the files under lib/routes/. Edit the markers'
// contents only through sync; everything outside them is yours.

// keta_files:imports
import 'routes/health.dart' as health;
import 'routes/session.dart' as session;
import 'routes/uploads.dart' as uploads;
import 'routes/users.dart' as users;
// keta_files:end

/// Builds the fully-configured application: the middleware stack plus every
/// discovered route file. Matches the register-based example — only the way
/// routes reach the app differs.
/// [requestTimeout] is a parameter so the ordering is testable: a test cannot
/// wait ten seconds to find out that a 504 lost its CORS headers.
///
/// Order is not decoration, and the rule is one line: everything that can throw
/// must sit BELOW recover, and everything that decorates a response ABOVE it.
/// timeout, enforceSecurity and the handlers all signal by throwing, so recover
/// is what turns them into responses; cors adds headers to a response, and
/// `chain` skips that on an error, so a 504 raised above cors would reach the
/// browser as an opaque CORS failure instead of the status it is.
App<Env> buildApp({Duration requestTimeout = const Duration(seconds: 10)}) {
  final metrics = MetricsRegistry();
  final app = App<Env>()
    ..use(accessLog())
    ..use(cors(allowOrigins: const ['*']))
    ..use(recover())
    ..use(timeout(requestTimeout))
    ..use(otel(metrics: metrics))
    ..use(enforceSecurity(securityPolicy()))
    ..use(tx());
  register(app);
  app.get(
    '/metrics',
    metricsHandler(metrics),
    doc: const RouteDoc(summary: 'Prometheus metrics', security: [apiKey]),
  );
  return app;
}

/// The OpenAPI document for [buildApp] — byte-identical to the register-based
/// example's, which is the point of the file convention: only the way routes
/// reach the app differs.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp().routes,
  title: 'keta example',
  version: '0.1.0',
  security: apiDefaults,
);

/// Calls every route file's `register`. The body is generated — run
/// `dart run keta_files:sync` after adding a file under lib/routes/.
void register(App<Env> app) {
  // keta_files:routes
  health.register(app);
  session.register(app);
  uploads.register(app);
  users.register(app);
  // keta_files:end
}
