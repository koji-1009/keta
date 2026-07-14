import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_otel/keta_otel.dart';

import 'env.dart';

// The import and registration lines below are materialized by
// `dart run keta_files:sync` from the files under lib/routes/. Edit the markers'
// contents only through sync; everything outside them is yours.

// keta_files:imports
import 'routes/health.dart' as health;
import 'routes/uploads.dart' as uploads;
import 'routes/users.dart' as users;
// keta_files:end

/// Builds the fully-configured application: the middleware stack plus every
/// discovered route file. Matches the register-based example — only the way
/// routes reach the app differs.
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

/// Calls every route file's `register`. The body is generated — run
/// `dart run keta_files:sync` after adding a file under lib/routes/.
void register(App<Env> app) {
  // keta_files:routes
  health.register(app);
  uploads.register(app);
  users.register(app);
  // keta_files:end
}
