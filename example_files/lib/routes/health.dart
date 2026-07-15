import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import '../env.dart';

/// One route file = one `register`. keta_files discovers this file and wires
/// its registration into the manifest; nothing else imports it.
void register(App<Env> app) {
  // `security: []` is not "no opinion" — it is "public", and it overrides the
  // global default. A route that simply omits RouteDoc.security inherits the
  // default instead, which is why the distinction is worth showing.
  app.get(
    '/health',
    (c) => c.text('ok'),
    doc: const RouteDoc(summary: 'Liveness probe', security: []),
  );
}
