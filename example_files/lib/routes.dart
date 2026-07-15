import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

import 'auth.dart';
import 'env.dart';
import 'observability.dart';

// Everything between the markers below is materialized by
// `dart run keta_files:sync` from the tree under lib/routes/. Edit the tree, not
// the markers; everything outside them is yours.

// keta_files:imports
import 'routes/admin/ping.dart' as $admin_ping;
import 'routes/health.dart' as $health;
import 'routes/metrics.dart' as $metrics;
import 'routes/uploads.dart' as $uploads;
import 'routes/users.dart' as $users;
import 'routes/users/_id.dart' as $users_id;
import 'routes/users/_uid/tags/_index.dart' as $users_uid_tags_index;
import 'routes/whoami.dart' as $whoami;

// keta_files:end

/// Builds the fully-configured application.
///
/// [requestTimeout] is a parameter so the ordering below is testable: a test
/// cannot wait ten seconds to find out that a 504 lost its CORS headers, and an
/// untested ordering rule is a comment, not a rule.
///
/// Order is not decoration, and the rule is one line: everything that can throw
/// must sit BELOW recover, and everything that decorates a response ABOVE it.
/// timeout, enforceSecurity and the handlers all signal by throwing, so recover
/// is what turns them into responses; cors adds headers to a response, and
/// `chain` skips that on an error, so a 504 raised above cors would reach the
/// browser as an opaque CORS failure instead of the status it is. tx is
/// innermost, so a request the gate rejects opens no transaction.
App<Env> buildApp({Duration requestTimeout = const Duration(seconds: 10)}) {
  final app = App<Env>()
    ..use(accessLog())
    ..use(cors(allowOrigins: const ['*']))
    ..use(recover())
    ..use(timeout(requestTimeout))
    ..use(otel(metrics: metrics))
    ..use(enforceSecurity(securityPolicy()))
    ..use(tx());
  register(app);
  return app;
}

/// The route table, materialized from the tree. Every URL below is the location
/// of the file that serves it — `routes/users/_id.dart` is `/users/:id`, and
/// nothing inside that file says so.
///
/// Run `dart run keta_files:sync` after adding, moving, or removing a file under
/// lib/routes/. Moving a file changes its URL; that is the point.
void register(App<Env> app) {
  // keta_files:routes
  app.get(
    routeSegments(const ['admin', 'ping']),
    $admin_ping.get,
    doc: $admin_ping.getDoc,
  );
  app.get(routeSegments(const ['health']), $health.get, doc: $health.getDoc);
  app.get(routeSegments(const ['metrics']), $metrics.get, doc: $metrics.getDoc);
  app.post(
    routeSegments(const ['uploads']),
    $uploads.post,
    doc: $uploads.postDoc,
  );
  app.get(routeSegments(const ['users']), $users.get, doc: $users.getDoc);
  app.post(routeSegments(const ['users']), $users.post, doc: $users.postDoc);
  app.get(
    routeSegments(const ['users', ':id']),
    $users_id.get,
    doc: $users_id.getDoc,
  );
  app.put(
    routeSegments(const ['users', ':id']),
    $users_id.put,
    doc: $users_id.putDoc,
  );
  app.delete(
    routeSegments(const ['users', ':id']),
    $users_id.delete,
    doc: $users_id.deleteDoc,
  );
  app.get(
    routeSegments(const [
      'users',
      ':uid',
      'tags',
      ':index',
    ], $users_uid_tags_index.captures),
    $users_uid_tags_index.get,
  );
  app.get(routeSegments(const ['whoami']), $whoami.get, doc: $whoami.getDoc);
  // keta_files:end
}

/// The OpenAPI document for [buildApp] — byte-identical to the register-based
/// example's. That identity is now worth something: the tree has to denote
/// exactly the same route set, so passing it says the file convention loses
/// nothing, rather than saying both files were copy-pasted from each other.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp().routes,
  title: 'keta example',
  version: '0.1.0',
  security: apiDefaults,
);
