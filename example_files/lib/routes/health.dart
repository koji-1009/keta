import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/health` — because the file is `routes/health.dart`. Nothing here says so;
/// that is what makes the tree the route table.
///
/// One value, one name, one type: what this file serves is checked by the
/// compiler, not matched by a generator against a name it hoped to find.
final exported = Exported<Env>([const Get(_live, doc: _liveDoc)]);

/// `security: []` is not "no opinion" — it is "public", and it overrides the
/// global default. A route that omits it inherits the default instead.
const _liveDoc = RouteDoc(summary: 'Liveness probe', security: []);

Response _live(Context<Env> c) => c.text('ok');
