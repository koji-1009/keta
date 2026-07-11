import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';

import 'env.dart';
import 'routes.dart';

/// Builds the fully-configured application: middleware plus every route. Pure
/// and env-free, so it can build the OpenAPI shadow and be re-run per isolate.
App<Env> buildApp() {
  final app = App<Env>()
    ..use(accessLog())
    ..use(recover())
    ..use(tx());
  register(app);
  return app;
}
