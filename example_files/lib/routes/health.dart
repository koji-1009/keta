import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/health` — because the file is `routes/health.dart`. Nothing here says so;
/// that is what makes the tree the route table.
///
/// One file is one URL, so it is one value: what it serves, what it answers
/// with, and what the contract says about that are one thing.
final exported = Exported<Env>(
  get: Serve(
    (c) => c.text('ok'),
    // `security: []` is not "no opinion" — it is "public", and it overrides the
    // global default. A route that omits it inherits the default instead.
    doc: const RouteDoc(summary: 'Liveness probe', security: []),
  ),
);
