import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_otel/keta_otel.dart';

import 'auth.dart';
import 'env.dart';
import 'observability.dart';

// Everything between the markers below is materialized by
// `dart run keta_files:sync` from the tree under lib/routes/. Edit the tree, not
// the markers; everything outside them is yours.

// keta_files:imports
// dart format off
import 'routes/admin/ping.dart' as $admin_ping; // ignore: directives_ordering, library_prefixes
import 'routes/health.dart' as $health; // ignore: directives_ordering, library_prefixes
import 'routes/metrics.dart' as $metrics; // ignore: directives_ordering, library_prefixes
import 'routes/uploads.dart' as $uploads; // ignore: directives_ordering, library_prefixes
import 'routes/users.dart' as $users; // ignore: directives_ordering, library_prefixes
import 'routes/users/_id.dart' as $users_id; // ignore: directives_ordering, library_prefixes
import 'routes/users/_uid/tags/_index.dart' as $users_uid_tags_index; // ignore: directives_ordering, library_prefixes
import 'routes/whoami.dart' as $whoami; // ignore: directives_ordering, library_prefixes
import 'routes/admin/_middleware.dart' as $mw$admin; // ignore: directives_ordering, library_prefixes
// dart format on
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
  // Scoped here, not a global: otel records into this registry and
  // routes/metrics.dart scrapes it, and two apps in one isolate must not share
  // one — see observability.dart. provideMetrics hands it to the file-routed
  // metrics handler through the request store, the only channel it has.
  final metrics = MetricsRegistry();
  final app = App<Env>()
    ..use(accessLog())
    ..use(cors(allowOrigins: const ['*']))
    ..use(recover())
    ..use(timeout(requestTimeout))
    ..use(otel(metrics: metrics))
    ..use(provideMetrics(metrics))
    ..use(enforceSecurity(securityPolicy()))
    ..use(tx());
  register(app);
  return app;
}

/// The route table, materialized from the tree. Every URL below is the location
/// of the file that serves it — `routes/users/_id.dart` is `/users/:id`, and
/// nothing inside that file says so.
///
/// One line per file, and none of them says what the file answers: that is the
/// file's `exported` type, checked where it binds.
///
/// Run `dart run keta_files:sync` after adding, moving, or removing a file under
/// lib/routes/. Moving a file changes its URL; that is the point.
void register(App<Env> app) {
  // keta_files:routes
  // dart format off
  $admin_ping.exported.bind(app, const ['admin', 'ping'], [$mw$admin.scoped]);
  $health.exported.bind(app, const ['health']);
  $metrics.exported.bind(app, const ['metrics']);
  $uploads.exported.bind(app, const ['uploads']);
  $users.exported.bind(app, const ['users']);
  $users_id.exported.bind(app, const ['users', ':id']);
  $users_uid_tags_index.exported.bind(app, const ['users', ':uid', 'tags', ':index']);
  $whoami.exported.bind(app, const ['whoami']);
  // dart format on
  // keta_files:end
}

/// The OpenAPI document for [buildApp] — byte-identical to the register-based
/// example's *on the routes both trees serve*. `../register` has since grown
/// `/users/by-role/:role` and `/users/events`, neither mirrored here (see this
/// package's README), so the two documents disagree as wholes; `test/
/// files_test.dart`'s shared-surface test restricts `../register`'s document
/// to this tree's path set and asserts deep equality on that subset, so the
/// narrower claim stays a passing test rather than a comment nobody re-checks.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp().routes,
  title: 'keta example',
  version: '0.1.0',
  security: apiDefaults,
);
