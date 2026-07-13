import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';

import 'env.dart';

// The import and registration lines below are materialized by
// `dart run keta_files:sync` from the files under lib/routes/. Edit the markers'
// contents only through sync; everything outside them is yours.

// keta_files:imports
import 'routes/health.dart' as health;
import 'routes/users.dart' as users;
// keta_files:end

/// Builds the fully-configured application: middleware plus every discovered
/// route file. Pure and env-free, so it can build the OpenAPI shadow and be
/// re-run per isolate.
App<Env> buildApp() {
  final app = App<Env>()
    ..use(accessLog())
    ..use(recover())
    ..use(tx());
  register(app);
  return app;
}

/// Calls every route file's `register`. The body is generated — run
/// `dart run keta_files:sync` after adding a file under lib/routes/.
void register(App<Env> app) {
  // keta_files:routes
  health.register(app);
  users.register(app);
  // keta_files:end
}
