import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

import 'auth.dart';
import 'env.dart';
import 'routes.dart';

/// Builds the fully-configured application: middleware plus every route. Pure
/// and env-free, so it can build the OpenAPI shadow and be re-run per isolate.
///
/// The middleware stack shows the common cross-cutting concerns: access logging,
/// CORS, a request deadline, request metrics, error recovery, authentication,
/// and a transaction per request.
///
/// Order is not decoration, and the rule is one line: everything that can throw
/// must sit BELOW recover, and everything that decorates a response must sit
/// ABOVE it.
///
/// timeout, enforceSecurity and the handlers all signal by throwing
/// (GatewayTimeout, Unauthorized, NotFound...), so recover is what turns them
/// into responses. cors is above recover because it adds headers to a response
/// — `chain` skips that callback on an error, so a 504 or 401 raised above cors
/// would reach the browser with no access-control-allow-origin and be reported
/// as an opaque CORS failure instead of the status it is. accessLog is
/// outermost so it records what was actually sent, rejections included. tx is
/// innermost, so a request rejected by the gate opens no transaction.
///
/// Note that the gate applies to unmatched paths too: an anonymous request to a
/// URL that does not exist is answered 401, not 404 — the API declines to tell
/// a stranger which of its routes are real.
/// [requestTimeout] is a parameter so the ordering above is testable: a test
/// cannot wait ten seconds to find out that a 504 lost its CORS headers, and an
/// untested ordering rule is a comment, not a rule.
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
  // Metrics are not public: apiKey rather than the bearer everything else uses,
  // so the document carries two schemes and the gate honours both.
  app.get(
    '/metrics',
    metricsHandler(metrics),
    doc: const RouteDoc(summary: 'Prometheus metrics', security: [apiKey]),
  );
  return app;
}

/// The OpenAPI document for [buildApp], with the same defaults the runtime gate
/// enforces. Built here rather than in tool/openapi.dart so the contract test
/// and the emitted file cannot disagree about what the API requires.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp().routes,
  title: 'keta example',
  version: '0.1.0',
  security: apiDefaults,
);
