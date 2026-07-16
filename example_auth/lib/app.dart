import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'auth.dart';
import 'env.dart';

/// A public route plus an `/admin` subtree. Security is declared on the route
/// (`RouteDoc(security: [bearer])`) and enforced by a single upstream
/// `enforceSecurity` gate — the declaration drives the OpenAPI output, the
/// runtime 401, and (via scaffold) the contract test. Authorization (the role
/// guard → 403) stays ordinary app middleware.
App<Env> buildApp() {
  final app = App<Env>()
    ..use(recover())
    ..use(enforceSecurity(securityPolicy));

  app.get('/public', (c) => c.text('anyone can read this'));

  app.group('/admin')
    ..use(requireRole('admin'))
    ..get(
      '/whoami',
      (c) => c.json({'role': c.get(authRole)}),
      doc: const RouteDoc(
        success: Success(),
        security: [bearer],
        summary: 'The caller identity',
      ),
    );

  return app;
}
