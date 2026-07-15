import 'package:keta/keta.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/health` — because the file is `routes/health.dart`. Nothing here says so;
/// that is what makes the tree the route table.

/// `security: []` is not "no opinion" — it is "public", and it overrides the
/// global default. A route that omits it inherits the default instead.
const getDoc = RouteDoc(summary: 'Liveness probe', security: []);

Response get(Context<Env> c) => c.text('ok');
