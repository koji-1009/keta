import 'package:keta/keta.dart';

import 'auth.dart';
import 'env.dart';

/// A public route plus an `/admin` subtree guarded by the app-defined auth
/// middleware. Group middleware (auth, then the role guard) runs only on match
/// and short-circuits with 401/403 by throwing; `recover()` turns those into
/// responses.
App<Env> buildApp() {
  final app = App<Env>()..use(recover());

  app.get('/public', (c) => c.text('anyone can read this'));

  app.group('/admin')
    ..use(auth())
    ..use(requireRole('admin'))
    ..get('/whoami', (c) => c.json({'role': c.get(authRole)}));

  return app;
}
